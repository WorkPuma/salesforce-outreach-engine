/**
 * @description Handler class for External Call Platform Events.
 *              Creates/updates AI_Outreach_Call__c records, manages Case contact
 *              attempts (Call_Attempt_1__c / Call_Attempt_2__c), handles
 *              attempt-2 collisions with CaseComment + auto-close, and sets
 *              AI_Outreach_Optout__c on Account when a DNC response is received.
 *
 * Bulkification:
 *   - All SOQL queries are outside loops (4 queries max regardless of batch size)
 *   - DML operations use Database methods with allOrNone=false
 *   - Uses Sets/Maps for efficient lookups
 *
 * Platform Event Best Practices:
 *   - Uses EventBus.TriggerContext.currentContext().setResumeCheckpoint() for replay
 *   - Processes partial failures gracefully
 *   - Logs errors using Nebula Logger framework
 *
 * @author PumaTech
 * @date 2026-01-26
 */
public without sharing class External CallEventHandler {

    private static final String CLASS_NAME = 'External CallEventHandler';
    private static final String AI_OUTREACH_TAG = 'AI_Outreach';

    private static final Decimal CAMPAIGN_AWV = 178;
    private static final Decimal CAMPAIGN_NO_NEXT = 217;

    // Each campaign maps to ALL Case Types it may legitimately land on.
    // Campaign 217 (No Next) may surface on Off-Cadence cases when staff have
    // moved the patient off the standard cadence, so we must check both.
    private static final Map<Decimal, Set<String>> CAMPAIGN_TO_CASE_TYPES = new Map<Decimal, Set<String>>{
        CAMPAIGN_AWV     => new Set<String>{ 'AWV Scheduling' },
        CAMPAIGN_NO_NEXT => new Set<String>{ 'No Next Visit', 'Off-Cadence' }
    };

    // Statuses we never override from a AI_Outreach webhook — they reflect a
    // deliberate staff decision (or a closed case we shouldn't reopen).
    private static final Set<String> PROTECTED_STATUSES = new Set<String>{
        'Unengaged', 'Closed'
    };

    // Outcomes AI_Outreach sends when the patient was actually reached and the
    // call produced something staff needs to act on (whether the AI completed
    // Outcomes where AI_Outreach reached the patient. These always map to
    // In Progress / Left Message so PES can verify and follow up.
    //
    // 'escalated' is intentionally NOT in this set — see ESCALATED_OUTCOME
    // handling below. When the AI hands off to PES we leave the case exactly
    // where it was, do not stamp an attempt slot, and add a CaseComment so
    // PES has the AI's call context. Stamping a slot would falsely advance
    // the cadence and could auto-close before PES finishes the handoff.
    @TestVisible
    private static final Set<String> CONTACT_REACHED_OUTCOMES = new Set<String>{
        'resolved', 'unresolved'
    };

    private static final String ESCALATED_OUTCOME = 'escalated';

    // Direction marker for patient-initiated (inbound) calls. Anything that is
    // not this value is treated as outbound (the historical default).
    @TestVisible
    private static final String INBOUND_DIRECTION = 'Inbound';

    @TestVisible
    private static final Set<String> DNC_INDICATORS = new Set<String>{
        'dnc', 'do_not_call', 'do not call', 'opted out', 'opt-out'
    };

    /**
     * @description Process incoming External Call events and create/update records
     * @param events List of AI_Outreach_Call_Event__e platform events
     */
    public static void handleEvents(List<AI_Outreach_Call_Event__e> events) {
        if (events == null || events.isEmpty()) {
            return;
        }

        Logger.info('Processing ' + events.size() + ' External Call events')
            .addTag(CLASS_NAME)
            .addTag(AI_OUTREACH_TAG);

        Set<String> externalPatientIds = new Set<String>();
        Set<Decimal> sequenceIds = new Set<Decimal>();

        for (AI_Outreach_Call_Event__e evt : events) {
            if (String.isNotBlank(evt.External_Patient_Id__c)) {
                externalPatientIds.add(evt.External_Patient_Id__c);
            }
            if (evt.Sequence_Id__c != null) {
                sequenceIds.add(evt.Sequence_Id__c);
            }
        }

        Map<String, Id> patientIdToAccountId = getAccountsByPatientId(externalPatientIds);
        Logger.debug('Account lookup: ' + patientIdToAccountId.size() + ' accounts found for '
            + externalPatientIds.size() + ' patient IDs')
            .addTag(CLASS_NAME).addTag(AI_OUTREACH_TAG);

        Map<Decimal, AI_Outreach_Call__c> existingCallsBySequenceId = getExistingCallsBySequenceId(sequenceIds);

        // ── 1. Build AI_Outreach_Call__c records ──
        // Outbound calls dedupe on Sequence_Id__c; inbound calls have no
        // sequence and dedupe on Call_Id__c instead. Two upsert lists keep
        // the two external-id keys from colliding on a null sequence id.
        List<AI_Outreach_Call__c> outboundToUpsert = new List<AI_Outreach_Call__c>();
        List<AI_Outreach_Call__c> inboundToUpsert = new List<AI_Outreach_Call__c>();
        String lastReplayId = null;

        for (AI_Outreach_Call_Event__e evt : events) {
            Boolean isInbound = INBOUND_DIRECTION.equalsIgnoreCase(
                String.isBlank(evt.Direction__c) ? '' : evt.Direction__c.trim()
            );

            AI_Outreach_Call__c call = (!isInbound && evt.Sequence_Id__c != null
                && existingCallsBySequenceId.containsKey(evt.Sequence_Id__c))
                ? existingCallsBySequenceId.get(evt.Sequence_Id__c)
                : new AI_Outreach_Call__c();

            call.Sequence_Id__c = evt.Sequence_Id__c;
            call.Sequence_Definition_Id__c = evt.Sequence_Definition_Id__c;
            call.Direction__c = isInbound ? 'Inbound' : 'Outbound';
            if (evt.Call_Id__c != null && evt.Call_Id__c.isNumeric()) {
                call.Call_Id__c = Decimal.valueOf(evt.Call_Id__c);
            }
            call.Phone_Number__c = evt.Phone_Number__c;
            call.Status__c = evt.Status__c;
            call.Outcome__c = evt.Outcome__c;
            call.Was_Contact_Reached__c = evt.Was_Contact_Reached__c;
            call.Call_Count__c = evt.Call_Count__c;
            call.Duration_Seconds__c = evt.Duration_Seconds__c;
            call.Call_Started_At__c = evt.Call_Started_At__c;
            call.Call_Ended_At__c = evt.Call_Ended_At__c;
            call.Ended_Reason__c = evt.Ended_Reason__c;
            call.Summary__c = evt.Summary__c;
            call.Transcript__c = truncateText(evt.Transcript__c, 131072);
            call.Previous_AWV_Date__c = parseDate(evt.Previous_AWV_Date__c);
            call.External_Id__c = evt.External_Id__c;
            call.Received_At__c = evt.Received_At__c;

            if (String.isNotBlank(evt.External_Patient_Id__c)
                && patientIdToAccountId.containsKey(evt.External_Patient_Id__c)) {
                call.Account__c = patientIdToAccountId.get(evt.External_Patient_Id__c);
            }

            if (isInbound) {
                inboundToUpsert.add(call);
            } else {
                outboundToUpsert.add(call);
            }
            lastReplayId = evt.ReplayId;
        }

        upsertExternal Calls(outboundToUpsert, AI_Outreach_Call__c.Sequence_Id__c);
        upsertExternal Calls(inboundToUpsert, AI_Outreach_Call__c.Call_Id__c);

        // ── 2. Case integration + DNC opt-out (OUTBOUND ONLY) ──
        // Inbound calls have no campaign and must not touch AWV/NNV cases or
        // stamp attempt slots. They still create a AI_Outreach_Call__c above and
        // (below) are eligible for the DNC opt-out safety net.
        processCaseUpdates(events, patientIdToAccountId);
        // Care-item parallel path (AI_Outreach_Eligible Patient_Need__c) — soak with Case path
        AI_OutreachOutreachBridge.applyEvents(events, patientIdToAccountId);
        processInboundOptOut(events, patientIdToAccountId);

        // ── 3. Checkpoint & log ──
        if (lastReplayId != null) {
            EventBus.TriggerContext.currentContext().setResumeCheckpoint(lastReplayId);
        }
        Logger.saveLog();
    }

    // ────────────────────────────────────────────────────────────
    //  Case Integration
    // ────────────────────────────────────────────────────────────

    /**
     * @description Resolve Cases by Account + Campaign, update contact attempts,
     *              handle collisions, and flag DNC opt-outs.
     */
    @TestVisible
    private static void processCaseUpdates(
        List<AI_Outreach_Call_Event__e> events,
        Map<String, Id> patientIdToAccountId
    ) {
        Set<Id> accountIds = new Set<Id>();
        Set<String> neededCaseTypes = new Set<String>();

        for (AI_Outreach_Call_Event__e evt : events) {
            if (isInboundEvent(evt)) continue;
            Id acctId = resolveAccountId(evt, patientIdToAccountId);
            if (acctId == null) continue;
            accountIds.add(acctId);

            Set<String> caseTypes = CAMPAIGN_TO_CASE_TYPES.get(evt.Sequence_Definition_Id__c);
            if (caseTypes != null) {
                neededCaseTypes.addAll(caseTypes);
            }
        }

        if (accountIds.isEmpty() || neededCaseTypes.isEmpty()) {
            Logger.debug('No accounts or case types to process for case updates')
                .addTag(CLASS_NAME).addTag(AI_OUTREACH_TAG);
            return;
        }

        // Bulkified Case query — most-recently-created OPEN case per Account.
        // We key on Account only because a single AI_Outreach campaign may surface
        // on multiple eligible types (No Next Visit OR Off-Cadence).
        Map<Id, Case> accountToCaseMap = getOpenCasesByAccountAndType(
            accountIds, neededCaseTypes
        );
        Logger.debug('Case lookup: ' + accountToCaseMap.size() + ' open cases found')
            .addTag(CLASS_NAME).addTag(AI_OUTREACH_TAG);

        List<Case> casesToUpdate = new List<Case>();
        List<CaseComment> commentsToInsert = new List<CaseComment>();
        Map<Id, Account> accountsToOptOut = new Map<Id, Account>();
        Set<Id> caseIdsTouched = new Set<Id>();

        for (AI_Outreach_Call_Event__e evt : events) {
            if (isInboundEvent(evt)) continue;
            Id acctId = resolveAccountId(evt, patientIdToAccountId);
            if (acctId == null) continue;

            Set<String> caseTypes = CAMPAIGN_TO_CASE_TYPES.get(evt.Sequence_Definition_Id__c);
            if (caseTypes == null) continue;

            Case targetCase = accountToCaseMap.get(acctId);
            if (targetCase == null || !caseTypes.contains(targetCase.Type)) {
                Logger.debug('No open eligible case for Account ' + acctId
                    + ' (campaign ' + evt.Sequence_Definition_Id__c + ') — skipping case update')
                    .addTag(CLASS_NAME).addTag(AI_OUTREACH_TAG);
                continue;
            }

            // Establish the call time we'll use for stamping. Prefer the actual
            // call start; fall back to webhook receipt time so non-connected
            // calls (no started_at) still log as a real attempt.
            DateTime callTime = evt.Call_Started_At__c != null
                ? evt.Call_Started_At__c
                : (evt.Received_At__c != null ? evt.Received_At__c : DateTime.now());

            String outcomeLower = String.isNotBlank(evt.Outcome__c)
                ? evt.Outcome__c.toLowerCase().trim()
                : '';

            // Escalated handoff: the AI transferred the patient to PES (or
            // the patient asked for a human). PES is now driving the case
            // — we DO NOT change the disposition (Status/Sub_Status stay as
            // PES had them queued). However, we MUST stamp both attempt
            // slots so the next outreach run treats this case as exhausted
            // and does NOT submit it to AI_Outreach again. Otherwise tomorrow's
            // dbt candidate view would see Call_Attempt_2__c is null and
            // re-submit the patient that's already being handled by PES.
            // We also leave a CaseComment so PES has the AI's call context.
            if (outcomeLower == ESCALATED_OUTCOME) {
                Boolean stampedAny = false;
                if (targetCase.Call_Attempt_1__c == null) {
                    targetCase.Call_Attempt_1__c = callTime;
                    stampedAny = true;
                }
                if (targetCase.Call_Attempt_2__c == null) {
                    // Use callTime + 1ms to keep the two stamps distinct so
                    // staff scanning the case timeline can see both attempts
                    // came from the same AI_Outreach handoff event.
                    targetCase.Call_Attempt_2__c = callTime.addSeconds(1);
                    stampedAny = true;
                }
                targetCase.Rule_Engine__c =
                    'AI_Outreach - Escalated to PES; cadence marked exhausted, disposition unchanged';

                if (stampedAny && !caseIdsTouched.contains(targetCase.Id)) {
                    casesToUpdate.add(targetCase);
                    caseIdsTouched.add(targetCase.Id);
                }

                commentsToInsert.add(new CaseComment(
                    ParentId = targetCase.Id,
                    CommentBody = 'AI_Outreach AI escalated to PES at '
                        + callTime.format('yyyy-MM-dd HH:mm:ss z')
                        + '. Outcome: escalated (' + nullSafe(evt.Ended_Reason__c) + ').'
                        + ' Both attempt slots stamped to suppress re-submission;'
                        + ' Status and disposition left unchanged for PES to drive.'
                        + ' Summary: ' + truncateText(evt.Summary__c, 3500),
                    IsPublished = false
                ));
                Logger.info('AI_Outreach escalated handoff on Case '
                    + targetCase.CaseNumber + ' — both slots stamped, status untouched')
                    .addTag(CLASS_NAME).addTag(AI_OUTREACH_TAG);

                // DNC opt-out can still apply on an escalated call.
                if (isDncResponse(evt.Outcome__c) || isDncResponse(evt.Ended_Reason__c)) {
                    accountsToOptOut.put(acctId, new Account(
                        Id = acctId,
                        AI_Outreach_Optout__c = true
                    ));
                }
                continue;
            }

            Boolean caseModified = false;
            Integer slotFilled = 0; // 1 = attempt 1, 2 = attempt 2, 0 = both already full

            // Stamp the next empty attempt slot. We IGNORE evt.Call_Count__c
            // because AI_Outreach no longer counts cumulative attempts within a
            // sequence — each call we send is a fresh sequence with call_count=1.
            // The Case itself is the source of truth for how many attempts have
            // already been logged (whether by AI_Outreach, PES, or Prefect submission).
            if (targetCase.Call_Attempt_1__c == null) {
                targetCase.Call_Attempt_1__c = callTime;
                slotFilled = 1;
                caseModified = true;
            } else if (targetCase.Call_Attempt_2__c == null) {
                targetCase.Call_Attempt_2__c = callTime;
                slotFilled = 2;
                caseModified = true;
            } else {
                // Both slots already filled before this webhook — record an
                // audit trail comment so staff can see External Called again.
                commentsToInsert.add(new CaseComment(
                    ParentId = targetCase.Id,
                    CommentBody = 'AI_Outreach AI call received at '
                        + callTime.format('yyyy-MM-dd HH:mm:ss z')
                        + ' but both attempt slots were already populated.'
                        + ' Outcome: ' + nullSafe(evt.Outcome__c)
                        + '. Summary: ' + truncateText(evt.Summary__c, 2000),
                    IsPublished = false
                ));
                Logger.info('Both attempt slots full on Case ' + targetCase.CaseNumber
                    + ' — adding CaseComment only')
                    .addTag(CLASS_NAME).addTag(AI_OUTREACH_TAG);
            }

            // Apply disposition (Status + Sub_Status__c) based on what AI_Outreach
            // returned and which attempt slot was just filled. Skip status
            // changes for cases in protected states (Unengaged or already
            // Closed) so staff decisions are never overridden.
            if (slotFilled > 0 && !PROTECTED_STATUSES.contains(targetCase.Status)) {
                applyDisposition(targetCase, evt, slotFilled);
                caseModified = true;
            }

            if (caseModified && !caseIdsTouched.contains(targetCase.Id)) {
                casesToUpdate.add(targetCase);
                caseIdsTouched.add(targetCase.Id);
            }

            // DNC opt-out check
            if (isDncResponse(evt.Outcome__c) || isDncResponse(evt.Ended_Reason__c)) {
                accountsToOptOut.put(acctId, new Account(
                    Id = acctId,
                    AI_Outreach_Optout__c = true
                ));
                Logger.info('DNC detected for Account ' + acctId
                    + ' — setting AI_Outreach_Optout__c = true')
                    .addTag(CLASS_NAME).addTag(AI_OUTREACH_TAG);
            }
        }

        // DML: Case updates
        if (!casesToUpdate.isEmpty()) {
            List<Database.SaveResult> caseResults = Database.update(casesToUpdate, false);
            logSaveResults(caseResults, casesToUpdate, 'Case');
        }

        // DML: CaseComments
        if (!commentsToInsert.isEmpty()) {
            List<Database.SaveResult> commentResults = Database.insert(commentsToInsert, false);
            logSaveResults(commentResults, commentsToInsert, 'CaseComment');
        }

        // DML: Account opt-outs
        if (!accountsToOptOut.isEmpty()) {
            List<Database.SaveResult> acctResults = Database.update(
                accountsToOptOut.values(), false
            );
            logSaveResults(acctResults, accountsToOptOut.values(), 'Account Opt-Out');
        }
    }

    // ────────────────────────────────────────────────────────────
    //  Disposition Mapping
    // ────────────────────────────────────────────────────────────

    /**
     * @description Translate AI_Outreach's call outcome into a Status/Sub_Status
     *              pair on the Case. Mirrors how PES dispositions calls today:
     *              voicemail / no-answer on attempt 1 → "In Progress / Left
     *              Message", on attempt 2 → "Closed / Unable to Reach".
     *              Engaged calls (resolved / escalated / unresolved) move the
     *              case to "In Progress / Left Message" so PES can
     *              verify and follow through, regardless of which attempt.
     *
     * @param targetCase     The Case being updated (mutated in place)
     * @param evt            The AI_Outreach_Call_Event__e with outcome/ended_reason
     * @param slotFilled     1 if this webhook just stamped Attempt 1, 2 if it
     *                       just stamped Attempt 2
     */
    @TestVisible
    private static void applyDisposition(
        Case targetCase,
        AI_Outreach_Call_Event__e evt,
        Integer slotFilled
    ) {
        String outcome = String.isNotBlank(evt.Outcome__c)
            ? evt.Outcome__c.toLowerCase().trim()
            : '';

        // Patient was reached and the call produced engagement (whether the
        // AI completed, the patient hung up after engaging, or asked for a
        // human). PES still needs to verify / follow up, regardless of slot.
        if (CONTACT_REACHED_OUTCOMES.contains(outcome)) {
            // Needs Call Back is only valid under Response Received (dependent
            // picklist). Under In Progress the valid sub-status is Left Message.
            targetCase.Status = 'In Progress';
            targetCase.Sub_Status__c = 'Left Message';
            targetCase.Rule_Engine__c =
                'AI_Outreach - Attempt ' + slotFilled
                + ' reached patient (' + outcome + '); kept In Progress';
            return;
        }

        // Default branch: outcome is 'unreachable', null, or anything else
        // we don't explicitly recognise. Treat as a non-contact call.
        // Attempt 1 → "Left Message" (matches PES behaviour for VM / no-answer).
        // Attempt 2 → "Unable to Reach" (closes the case).
        if (slotFilled == 1) {
            targetCase.Status = 'In Progress';
            targetCase.Sub_Status__c = 'Left Message';
            targetCase.Rule_Engine__c =
                'AI_Outreach - Attempt 1 left voicemail / unreachable ('
                + nullSafe(evt.Outcome__c) + ')';
        } else {
            targetCase.Status = 'Closed';
            targetCase.Sub_Status__c = 'Unable to Reach';
            targetCase.Rule_Engine__c =
                'AI_Outreach - Attempt 2 unreachable; closed Unable to Reach ('
                + nullSafe(evt.Outcome__c) + ')';
        }
    }

    // ────────────────────────────────────────────────────────────
    //  SOQL Helpers
    // ────────────────────────────────────────────────────────────

    private static Map<String, Id> getAccountsByPatientId(Set<String> patientIds) {
        Map<String, Id> result = new Map<String, Id>();
        if (patientIds.isEmpty()) return result;

        for (Account acc : [
            SELECT Id, SourceSystemIdentifier
            FROM Account
            WHERE SourceSystemIdentifier IN :patientIds
        ]) {
            result.put(acc.SourceSystemIdentifier, acc.Id);
        }
        return result;
    }

    private static Map<Decimal, AI_Outreach_Call__c> getExistingCallsBySequenceId(Set<Decimal> sequenceIds) {
        Map<Decimal, AI_Outreach_Call__c> result = new Map<Decimal, AI_Outreach_Call__c>();
        if (sequenceIds.isEmpty()) return result;

        for (AI_Outreach_Call__c call : [
            SELECT Id, Sequence_Id__c
            FROM AI_Outreach_Call__c
            WHERE Sequence_Id__c IN :sequenceIds
        ]) {
            result.put(call.Sequence_Id__c, call);
        }
        return result;
    }

    /**
     * @description Query open Cases by Account, filtered to the union of eligible
     *              Types across the campaigns we are processing. Returns the most
     *              recently created OPEN case per Account so the per-event loop
     *              can confirm Type compatibility against the matched case.
     */
    @TestVisible
    private static Map<Id, Case> getOpenCasesByAccountAndType(
        Set<Id> accountIds,
        Set<String> caseTypes
    ) {
        Map<Id, Case> result = new Map<Id, Case>();
        if (accountIds.isEmpty() || caseTypes.isEmpty()) return result;

        for (Case c : [
            SELECT Id, CaseNumber, AccountId, Type, Status, Sub_Status__c,
                   Call_Attempt_1__c, Call_Attempt_2__c, Call_Attempt_3__c, Rule_Engine__c
            FROM Case
            WHERE AccountId IN :accountIds
              AND Type IN :caseTypes
              AND IsClosed = false
            ORDER BY CreatedDate DESC
        ]) {
            if (!result.containsKey(c.AccountId)) {
                result.put(c.AccountId, c);
            }
        }
        return result;
    }

    // ────────────────────────────────────────────────────────────
    //  DML Helpers
    // ────────────────────────────────────────────────────────────

    private static void upsertExternal Calls(
        List<AI_Outreach_Call__c> callsToUpsert,
        Schema.SObjectField externalIdField
    ) {
        if (callsToUpsert.isEmpty()) return;

        List<Database.UpsertResult> results = Database.upsert(
            callsToUpsert, externalIdField, false
        );

        Integer successCount = 0;
        Integer failureCount = 0;

        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                successCount++;
            } else {
                failureCount++;
                for (Database.Error err : results[i].getErrors()) {
                    Logger.error('Failed to upsert External Call: '
                        + err.getStatusCode() + ' - ' + err.getMessage())
                        .addTag(CLASS_NAME).addTag(AI_OUTREACH_TAG).addTag('UpsertError')
                        .setRecord(callsToUpsert[i]);
                }
            }
        }

        String level = failureCount > 0 ? 'warn' : 'info';
        String msg = 'External Call upsert: ' + successCount + ' succeeded, ' + failureCount + ' failed';
        if (failureCount > 0) {
            Logger.warn(msg).addTag(CLASS_NAME).addTag(AI_OUTREACH_TAG);
        } else {
            Logger.info(msg).addTag(CLASS_NAME).addTag(AI_OUTREACH_TAG);
        }
    }

    private static void logSaveResults(List<Database.SaveResult> results, List<SObject> records, String label) {
        Integer failures = 0;
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                failures++;
                for (Database.Error err : results[i].getErrors()) {
                    Logger.error(label + ' DML error: ' + err.getStatusCode() + ' - ' + err.getMessage())
                        .addTag(CLASS_NAME).addTag(AI_OUTREACH_TAG);
                }
            }
        }
        if (failures > 0) {
            Logger.warn(label + ' DML: ' + (results.size() - failures) + ' succeeded, ' + failures + ' failed')
                .addTag(CLASS_NAME).addTag(AI_OUTREACH_TAG);
        } else {
            Logger.info(label + ' DML: ' + results.size() + ' succeeded')
                .addTag(CLASS_NAME).addTag(AI_OUTREACH_TAG);
        }
    }

    // ────────────────────────────────────────────────────────────
    //  Utility Methods
    // ────────────────────────────────────────────────────────────

    private static Id resolveAccountId(
        AI_Outreach_Call_Event__e evt,
        Map<String, Id> patientIdToAccountId
    ) {
        if (String.isNotBlank(evt.External_Patient_Id__c)
            && patientIdToAccountId.containsKey(evt.External_Patient_Id__c)) {
            return patientIdToAccountId.get(evt.External_Patient_Id__c);
        }
        return null;
    }

    @TestVisible
    private static Boolean isInboundEvent(AI_Outreach_Call_Event__e evt) {
        return String.isNotBlank(evt.Direction__c)
            && INBOUND_DIRECTION.equalsIgnoreCase(evt.Direction__c.trim());
    }

    /**
     * @description DNC opt-out safety net for INBOUND calls. Inbound calls
     *              skip all Case/campaign processing, but a patient who says
     *              "do not call me" on an inbound call must still be flagged
     *              so future AI_Outreach outbound outreach excludes them.
     */
    @TestVisible
    private static void processInboundOptOut(
        List<AI_Outreach_Call_Event__e> events,
        Map<String, Id> patientIdToAccountId
    ) {
        Map<Id, Account> accountsToOptOut = new Map<Id, Account>();

        for (AI_Outreach_Call_Event__e evt : events) {
            if (!isInboundEvent(evt)) continue;
            Id acctId = resolveAccountId(evt, patientIdToAccountId);
            if (acctId == null) continue;

            if (isDncResponse(evt.Outcome__c) || isDncResponse(evt.Ended_Reason__c)) {
                accountsToOptOut.put(acctId, new Account(
                    Id = acctId,
                    AI_Outreach_Optout__c = true
                ));
                Logger.info('DNC detected on INBOUND call for Account ' + acctId
                    + ' — setting AI_Outreach_Optout__c = true')
                    .addTag(CLASS_NAME).addTag(AI_OUTREACH_TAG);
            }
        }

        if (!accountsToOptOut.isEmpty()) {
            List<Database.SaveResult> acctResults = Database.update(
                accountsToOptOut.values(), false
            );
            logSaveResults(acctResults, accountsToOptOut.values(), 'Inbound Account Opt-Out');
        }
    }

    @TestVisible
    private static Boolean isDncResponse(String fieldValue) {
        if (String.isBlank(fieldValue)) return false;
        String lower = fieldValue.toLowerCase();
        for (String indicator : DNC_INDICATORS) {
            if (lower.contains(indicator)) return true;
        }
        return false;
    }

    private static String truncateText(String text, Integer maxLength) {
        if (String.isBlank(text)) return text;
        if (text.length() <= maxLength) return text;
        return text.substring(0, maxLength - 3) + '...';
    }

    private static String nullSafe(String val) {
        return String.isBlank(val) ? '(none)' : val;
    }

    private static Date parseDate(String dateStr) {
        if (String.isBlank(dateStr)) return null;

        try {
            List<String> parts = dateStr.split('-');
            if (parts.size() == 3) {
                return Date.newInstance(
                    Integer.valueOf(parts[2]),
                    Integer.valueOf(parts[0]),
                    Integer.valueOf(parts[1])
                );
            }
        } catch (Exception e) {
            Logger.warn('Could not parse date: ' + dateStr)
                .addTag(CLASS_NAME).addTag(AI_OUTREACH_TAG).addTag('DateParseError');
        }
        return null;
    }
}
