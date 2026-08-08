/**
 * Reconcile outbound AI_Outreach_Call__c campaign rows (178 AWV / 217 No Next)
 * onto care-item Outreach_Event__c Attempt Made (Channel=AI_Outreach)
 * only when a matching active Need (Pending / In Progress / Snoozed) exists.
 *
 * Source of truth: AI_Outreach_Call__c where Direction__c = Outbound.
 * Inbound = patient-initiated — never written as campaign outreach attempts.
 *
 * Fixes prior backfill that stamped legacy-ai_outreach:* events as Channel=Phone,
 * and inserts missing Attempt Made rows when no near duplicate exists.
 * Near Phone Attempt Made within 2 minutes is reclassified to AI_Outreach
 * (not skipped / not duplicated).
 */
public without sharing class External CallCareItemReconcileBatch
  implements Database.Batchable<SObject>, Database.Stateful {
  @TestVisible
  static final Map<Decimal, String> CAMPAIGN_TO_NEED = new Map<Decimal, String>{
    178 => 'AWV',
    217 => 'NO_NEXT'
  };
  @TestVisible
  static final Long NEAR_MS = 120000;

  Integer flipped = 0;
  Integer inserted = 0;
  Integer reclassNear = 0;
  Integer skipped = 0;
  Integer noNeed = 0;

  public Database.QueryLocator start(Database.BatchableContext bc) {
    return Database.getQueryLocator(
      [
        SELECT Id, Account__c, Sequence_Definition_Id__c, Sequence_Id__c,
               Outcome__c, Call_Started_At__c, Received_At__c, CreatedDate,
               Direction__c
        FROM AI_Outreach_Call__c
        WHERE Direction__c = 'Outbound'
          AND Sequence_Definition_Id__c IN (178, 217)
          AND Account__c != null
        ORDER BY Account__c, Call_Started_At__c ASC NULLS LAST, CreatedDate ASC
      ]
    );
  }

  public void execute(Database.BatchableContext bc, List<AI_Outreach_Call__c> scope) {
    if (scope == null || scope.isEmpty()) return;

    Set<Id> accountIds = new Set<Id>();
    Set<String> needTypes = new Set<String>();
    Set<String> ai_outreachKeys = new Set<String>();
    for (AI_Outreach_Call__c c : scope) {
      if (c.Direction__c == 'Inbound') continue;
      accountIds.add(c.Account__c);
      String nt = CAMPAIGN_TO_NEED.get(c.Sequence_Definition_Id__c);
      if (nt != null) needTypes.add(nt);
      ai_outreachKeys.add('legacy-ai_outreach:' + String.valueOf(c.Id));
      if (c.Sequence_Id__c != null)
        ai_outreachKeys.add('ai_outreach-attempt:' + String.valueOf(c.Sequence_Id__c));
    }
    if (accountIds.isEmpty()) return;

    Map<String, Patient_Need__c> needByAcctType = loadNeeds(accountIds, needTypes);
    Set<Id> needIds = new Set<Id>();
    for (Patient_Need__c n : needByAcctType.values()) needIds.add(n.Id);

    Map<String, Outreach_Event__c> byKey = loadEventsByKeys(ai_outreachKeys);
    Map<Id, List<Outreach_Event__c>> attemptsByNeed = loadAttemptsByNeed(needIds);

    List<Outreach_Event__c> toUpsert = new List<Outreach_Event__c>();
    Set<Id> queuedIds = new Set<Id>();

    for (AI_Outreach_Call__c c : scope) {
      if (c.Direction__c == 'Inbound') { skipped++; continue; }
      String needType = CAMPAIGN_TO_NEED.get(c.Sequence_Definition_Id__c);
      if (needType == null) { skipped++; continue; }
      Patient_Need__c need = needByAcctType.get(
        String.valueOf(c.Account__c) + ':' + needType
      );
      if (need == null) { noNeed++; continue; }

      Datetime at = callTime(c);
      if (at == null) { skipped++; continue; }

      String callKey = 'legacy-ai_outreach:' + String.valueOf(c.Id);
      String seqKey = c.Sequence_Id__c == null
        ? null
        : 'ai_outreach-attempt:' + String.valueOf(c.Sequence_Id__c);

      Outreach_Event__c byCall = byKey.get(callKey);
      if (byCall != null) {
        if (byCall.Channel__c != 'AI_Outreach' || byCall.Event_Type__c != 'Attempt Made') {
          applyAI_OutreachFields(byCall, need, c, at);
          if (byCall.Id != null && !queuedIds.contains(byCall.Id)) {
            toUpsert.add(byCall);
            queuedIds.add(byCall.Id);
          } else if (byCall.Id == null) {
            toUpsert.add(byCall);
          }
          flipped++;
        } else {
          skipped++;
        }
        continue;
      }

      if (seqKey != null) {
        Outreach_Event__c bySeq = byKey.get(seqKey);
        if (bySeq != null) {
          if (bySeq.Channel__c != 'AI_Outreach') {
            applyAI_OutreachFields(bySeq, need, c, at);
            if (bySeq.Id != null && !queuedIds.contains(bySeq.Id)) {
              toUpsert.add(bySeq);
              queuedIds.add(bySeq.Id);
            }
            flipped++;
          } else {
            skipped++;
          }
          continue;
        }
      }

      List<Outreach_Event__c> attempts = attemptsByNeed.containsKey(need.Id)
        ? attemptsByNeed.get(need.Id)
        : new List<Outreach_Event__c>();

      Outreach_Event__c near = nearestAttempt(attempts, at);
      if (near != null) {
        if (near.Channel__c == 'AI_Outreach') {
          skipped++;
          continue;
        }
        // Phone (or other) near the External Call → reclassify, do not insert
        applyAI_OutreachFields(near, need, c, near.Event_At__c != null ? near.Event_At__c : at);
        if (near.Id != null && !queuedIds.contains(near.Id)) {
          toUpsert.add(near);
          queuedIds.add(near.Id);
        }
        reclassNear++;
        continue;
      }

      String prog = needType == 'AWV' ? 'AWV' : 'No Next';
      String outcome = String.isBlank(c.Outcome__c) ? 'AI_Outreach' : c.Outcome__c;
      Outreach_Event__c ev = new Outreach_Event__c(
        Patient__c = need.Patient__c,
        Need__c = need.Id,
        Episode__c = need.Episode__c,
        Event_Type__c = 'Attempt Made',
        Channel__c = 'AI_Outreach',
        Outcome__c = outcome,
        Detail__c = 'AI_Outreach invoked for ' + prog + ' (campaign '
          + String.valueOf(c.Sequence_Definition_Id__c) + '): '
          + (String.isBlank(c.Outcome__c) ? 'call recorded' : c.Outcome__c)
          + '. (reconcile AI_Outreach_Call ' + c.Id + ')',
        Rule_Id__c = need.Rule_Id__c,
        Event_At__c = at,
        Shadow__c = false,
        Idempotency_Key__c = callKey
      );
      toUpsert.add(ev);
      byKey.put(callKey, ev);
      attempts.add(ev);
      attemptsByNeed.put(need.Id, attempts);
      inserted++;
    }

    if (!toUpsert.isEmpty()) {
      Database.UpsertResult[] ers = Database.upsert(
        toUpsert, Outreach_Event__c.Idempotency_Key__c, false
      );
      for (Database.UpsertResult er : ers) {
        if (!er.isSuccess()) skipped++;
      }
    }
  }

  public void finish(Database.BatchableContext bc) {
    System.debug(LoggingLevel.INFO,
      'External CallCareItemReconcileBatch done flipped=' + flipped
        + ' reclassNear=' + reclassNear + ' inserted=' + inserted
        + ' noNeed=' + noNeed + ' skipped=' + skipped);
  }

  @TestVisible
  static void applyAI_OutreachFields(
    Outreach_Event__c ev,
    Patient_Need__c need,
    AI_Outreach_Call__c c,
    Datetime at
  ) {
    String prog = need.Need_Type__c == 'AWV' ? 'AWV' : 'No Next';
    String outcome = String.isBlank(c.Outcome__c) ? 'AI_Outreach' : c.Outcome__c;
    ev.Event_Type__c = 'Attempt Made';
    ev.Channel__c = 'AI_Outreach';
    ev.Outcome__c = outcome;
    ev.Detail__c = 'AI_Outreach invoked for ' + prog + ' (campaign '
      + String.valueOf(c.Sequence_Definition_Id__c) + '): ' + outcome
      + '. (reconcile AI_Outreach_Call ' + c.Id + ')';
    if (ev.Event_At__c == null) ev.Event_At__c = at;
  }

  static Datetime callTime(AI_Outreach_Call__c c) {
    if (c.Call_Started_At__c != null) return c.Call_Started_At__c;
    if (c.Received_At__c != null) return c.Received_At__c;
    return c.CreatedDate;
  }

  static Outreach_Event__c nearestAttempt(List<Outreach_Event__c> attempts, Datetime at) {
    if (attempts == null || at == null) return null;
    Outreach_Event__c best = null;
    Long bestDiff = null;
    for (Outreach_Event__c e : attempts) {
      if (e.Event_At__c == null) continue;
      Long diff = Math.abs(e.Event_At__c.getTime() - at.getTime());
      if (diff > NEAR_MS) continue;
      if (bestDiff == null || diff < bestDiff) {
        bestDiff = diff;
        best = e;
      }
    }
    return best;
  }

  static Map<String, Patient_Need__c> loadNeeds(Set<Id> accountIds, Set<String> needTypes) {
    Map<String, Patient_Need__c> best = new Map<String, Patient_Need__c>();
    if (accountIds.isEmpty() || needTypes.isEmpty()) return best;
    for (Patient_Need__c n : [
      SELECT Id, Patient__c, Need_Type__c, Episode__c, Rule_Id__c, Shadow__c, State__c, CreatedDate
      FROM Patient_Need__c
      WHERE Patient__c IN :accountIds
        AND Need_Type__c IN :needTypes
        AND Shadow__c = FALSE
        AND State__c IN ('Pending', 'In Progress', 'Snoozed')
      ORDER BY CreatedDate DESC
    ]) {
      String key = String.valueOf(n.Patient__c) + ':' + n.Need_Type__c;
      if (!best.containsKey(key)) best.put(key, n);
    }
    return best;
  }

  static Map<String, Outreach_Event__c> loadEventsByKeys(Set<String> keys) {
    Map<String, Outreach_Event__c> out = new Map<String, Outreach_Event__c>();
    if (keys == null || keys.isEmpty()) return out;
    for (Outreach_Event__c e : [
      SELECT Id, Need__c, Channel__c, Event_Type__c, Event_At__c, Idempotency_Key__c,
             Detail__c, Outcome__c
      FROM Outreach_Event__c
      WHERE Idempotency_Key__c IN :keys
    ]) {
      out.put(e.Idempotency_Key__c, e);
    }
    return out;
  }

  static Map<Id, List<Outreach_Event__c>> loadAttemptsByNeed(Set<Id> needIds) {
    Map<Id, List<Outreach_Event__c>> out = new Map<Id, List<Outreach_Event__c>>();
    if (needIds == null || needIds.isEmpty()) return out;
    for (Outreach_Event__c e : [
      SELECT Id, Need__c, Event_At__c, Channel__c, Event_Type__c, Idempotency_Key__c,
             Detail__c, Outcome__c
      FROM Outreach_Event__c
      WHERE Need__c IN :needIds AND Event_Type__c = 'Attempt Made'
    ]) {
      if (!out.containsKey(e.Need__c)) out.put(e.Need__c, new List<Outreach_Event__c>());
      out.get(e.Need__c).add(e);
    }
    return out;
  }
}
