/**
 * @description Test class for External CallEventHandler
 *              Covers AI_Outreach_Call__c upsert, Case contact attempt management,
 *              attempt-2 collision handling, and DNC opt-out logic.
 * @author PumaTech
 * @date 2026-01-26
 */
@isTest
private class External CallEventHandlerTest {

    private static final Decimal SEQ_DEF_AWV = 178;
    private static final Decimal SEQ_DEF_NO_NEXT = 217;

    @TestSetup
    static void setupTestData() {
        Id personAccountRTId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
            .get('PersonAccount').getRecordTypeId();

        Account testAccount = new Account(
            LastName = 'Test Patient',
            SourceSystemIdentifier = '114232',
            RecordTypeId = personAccountRTId
        );
        insert testAccount;

        Account testAccount2 = new Account(
            LastName = 'DNC Patient',
            SourceSystemIdentifier = '114999',
            RecordTypeId = personAccountRTId
        );
        insert testAccount2;

        // AWV Scheduling Case (Scheduling record type)
        Id schedulingRTId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName()
            .get('Scheduling').getRecordTypeId();

        Case awvCase = new Case(
            AccountId = testAccount.Id,
            RecordTypeId = schedulingRTId,
            Type = 'AWV Scheduling',
            Status = 'In Progress',
            Call_Attempt_1__c = DateTime.now().addDays(-1),
            Subject = 'AWV Scheduling - Test'
        );
        insert awvCase;

        // No Next Visit Case
        Id noNextRTId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName()
            .get('No_Next_Visit').getRecordTypeId();

        Case noNextCase = new Case(
            AccountId = testAccount2.Id,
            RecordTypeId = noNextRTId,
            Type = 'No Next Visit',
            Status = 'In Progress',
            Call_Attempt_1__c = DateTime.now().addDays(-2),
            Subject = 'No Next Visit - DNC Test'
        );
        insert noNextCase;
    }

    // ── AI_Outreach_Call__c Upsert Tests ──

    @isTest
    static void testHandleEvents_NewRecord() {
        Account testAccount = [SELECT Id, SourceSystemIdentifier FROM Account
            WHERE SourceSystemIdentifier = '114232' LIMIT 1];

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 12345,
                Sequence_Definition_Id__c = SEQ_DEF_AWV,
                External_Patient_Id__c = '114232',
                Phone_Number__c = '+17028303827',
                Status__c = 'ended',
                Outcome__c = 'completed',
                Was_Contact_Reached__c = true,
                Call_Count__c = 1,
                Duration_Seconds__c = 120,
                Call_Started_At__c = DateTime.now(),
                Summary__c = 'Test call summary',
                Transcript__c = 'Test transcript content',
                Previous_AWV_Date__c = '02-10-2025',
                External_Id__c = 'test-uuid-1234',
                Received_At__c = DateTime.now()
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        List<AI_Outreach_Call__c> calls = [
            SELECT Id, Sequence_Id__c, Account__c, Status__c, Previous_AWV_Date__c
            FROM AI_Outreach_Call__c WHERE Sequence_Id__c = 12345
        ];

        System.assertEquals(1, calls.size(), 'Should create one External Call record');
        System.assertEquals(testAccount.Id, calls[0].Account__c, 'Should link to Account');
        System.assertEquals('ended', calls[0].Status__c, 'Status should match');
        System.assertEquals(Date.newInstance(2025, 2, 10), calls[0].Previous_AWV_Date__c,
            'Date should be parsed');
    }

    @isTest
    static void testHandleEvents_UpdateExisting() {
        Account testAccount = [SELECT Id FROM Account WHERE SourceSystemIdentifier = '114232' LIMIT 1];

        AI_Outreach_Call__c existingCall = new AI_Outreach_Call__c(
            Sequence_Id__c = 99999,
            Status__c = 'in_progress',
            Account__c = testAccount.Id
        );
        insert existingCall;

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 99999,
                Status__c = 'ended',
                Outcome__c = 'completed',
                Was_Contact_Reached__c = true
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        AI_Outreach_Call__c updatedCall = [
            SELECT Id, Status__c, Outcome__c FROM AI_Outreach_Call__c WHERE Sequence_Id__c = 99999
        ];
        System.assertEquals('ended', updatedCall.Status__c);
        System.assertEquals('completed', updatedCall.Outcome__c);
    }

    @isTest
    static void testHandleEvents_NoAccount() {
        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 55555,
                External_Patient_Id__c = 'UNKNOWN_ID',
                Status__c = 'ended'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        AI_Outreach_Call__c call = [SELECT Id, Account__c FROM AI_Outreach_Call__c WHERE Sequence_Id__c = 55555];
        System.assertEquals(null, call.Account__c, 'Account should be null for unknown patient');
    }

    @isTest
    static void testHandleEvents_EmptyList() {
        Test.startTest();
        External CallEventHandler.handleEvents(new List<AI_Outreach_Call_Event__e>());
        External CallEventHandler.handleEvents(null);
        Test.stopTest();
        System.assert(true, 'Should handle empty/null lists gracefully');
    }

    @isTest
    static void testHandleEvents_LongTranscript() {
        String longTranscript = 'A'.repeat(150000);

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 77777,
                Transcript__c = longTranscript,
                Status__c = 'ended'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        AI_Outreach_Call__c call = [SELECT Id, Transcript__c FROM AI_Outreach_Call__c WHERE Sequence_Id__c = 77777];
        System.assertEquals(131072, call.Transcript__c.length());
        System.assert(call.Transcript__c.endsWith('...'));
    }

    // ── Case Contact Attempt Tests ──

    @isTest
    static void testAttempt2_Unreachable_ClosesUnableToReach() {
        // Setup leaves the AWV case with Call_Attempt_1__c populated from a
        // prior submission. Webhook fills Attempt 2 with an 'unreachable'
        // outcome → case closes as Unable to Reach (matches PES disposition).
        Account testAccount = [SELECT Id FROM Account WHERE SourceSystemIdentifier = '114232' LIMIT 1];
        Case awvCase = [SELECT Id, Call_Attempt_1__c FROM Case
            WHERE AccountId = :testAccount.Id AND Type = 'AWV Scheduling' LIMIT 1];
        DateTime originalAttempt1 = awvCase.Call_Attempt_1__c;

        DateTime realCallTime = DateTime.now().addHours(-2);

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 30001,
                Sequence_Definition_Id__c = SEQ_DEF_AWV,
                External_Patient_Id__c = '114232',
                Status__c = 'ended',
                Outcome__c = 'unreachable',
                Ended_Reason__c = 'voicemail',
                Was_Contact_Reached__c = false,
                Call_Count__c = 1,
                Call_Started_At__c = realCallTime,
                Received_At__c = DateTime.now(),
                External_Id__c = 'attempt2-unreachable'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        Case updated = [SELECT Call_Attempt_1__c, Call_Attempt_2__c, Status, Sub_Status__c, Rule_Engine__c
            FROM Case WHERE Id = :awvCase.Id];

        System.assertEquals(originalAttempt1, updated.Call_Attempt_1__c,
            'Attempt 1 should NOT be overwritten');
        System.assertEquals(realCallTime, updated.Call_Attempt_2__c,
            'Attempt 2 should be stamped with the actual call time');
        System.assertEquals('Closed', updated.Status,
            'Unreachable on attempt 2 should close the case');
        System.assertEquals('Unable to Reach', updated.Sub_Status__c);
    }

    @isTest
    static void testAttempt1_VoicemailLeavesInProgress_LeftMessage() {
        // Vanessa's primary case: AI_Outreach left a voicemail on the first call.
        // Match PES disposition: In Progress / Left Message, do NOT close.
        Account testAccount = [SELECT Id FROM Account WHERE SourceSystemIdentifier = '114232' LIMIT 1];
        Case awvCase = [SELECT Id FROM Case
            WHERE AccountId = :testAccount.Id AND Type = 'AWV Scheduling' LIMIT 1];
        // Wipe attempt 1 so this webhook fills slot 1
        awvCase.Call_Attempt_1__c = null;
        awvCase.Status = 'New';
        update awvCase;

        DateTime callTime = DateTime.now().addMinutes(-15);

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 30100,
                Sequence_Definition_Id__c = SEQ_DEF_AWV,
                External_Patient_Id__c = '114232',
                Status__c = 'ended',
                Outcome__c = 'unreachable',
                Ended_Reason__c = 'voicemail',
                Was_Contact_Reached__c = false,
                Call_Count__c = 1,
                Call_Started_At__c = callTime,
                Received_At__c = DateTime.now(),
                External_Id__c = 'attempt1-vm'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        Case updated = [SELECT Call_Attempt_1__c, Status, Sub_Status__c, Rule_Engine__c
            FROM Case WHERE Id = :awvCase.Id];
        System.assertEquals(callTime, updated.Call_Attempt_1__c, 'Attempt 1 should be stamped');
        System.assertEquals('In Progress', updated.Status,
            'Voicemail on attempt 1 should keep the case In Progress');
        System.assertEquals('Left Message', updated.Sub_Status__c,
            'Voicemail on attempt 1 should disposition as Left Message');
    }

    @isTest
    static void testAttempt1_PatientResolved_MovesToResponseReceived() {
        // AI completed a productive conversation with the patient on attempt 1.
        // Should move case to In Progress / Left Message so PES
        // verifies and follows up — should NOT auto-close.
        Account testAccount = [SELECT Id FROM Account WHERE SourceSystemIdentifier = '114232' LIMIT 1];
        Case awvCase = [SELECT Id FROM Case
            WHERE AccountId = :testAccount.Id AND Type = 'AWV Scheduling' LIMIT 1];
        awvCase.Call_Attempt_1__c = null;
        awvCase.Status = 'New';
        update awvCase;

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 30101,
                Sequence_Definition_Id__c = SEQ_DEF_AWV,
                External_Patient_Id__c = '114232',
                Status__c = 'ended',
                Outcome__c = 'resolved',
                Ended_Reason__c = 'assistant-ended',
                Was_Contact_Reached__c = true,
                Call_Count__c = 1,
                Call_Started_At__c = DateTime.now().addMinutes(-10),
                Received_At__c = DateTime.now(),
                External_Id__c = 'attempt1-resolved'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        Case updated = [SELECT Status, Sub_Status__c FROM Case WHERE Id = :awvCase.Id];
        System.assertEquals('In Progress', updated.Status,
            'Resolved External Call should keep case In Progress');
        System.assertEquals('Left Message', updated.Sub_Status__c,
            'In Progress requires Left Message (Needs Call Back only under Response Received)');
    }

    @isTest
    static void testEscalated_HandoffStampsSlotsButLeavesDispositionAlone() {
        // When AI_Outreach escalates the call to a human (patient asked or AI
        // transferred), PES is now driving the case so we MUST NOT change
        // the disposition (Status/Sub_Status stay where PES had them queued).
        // BUT we DO stamp both attempt slots so the next outreach run sees
        // the cadence as exhausted and won't re-submit this patient to
        // AI_Outreach. The CaseComment carries the AI summary for PES context.
        Account testAccount = [SELECT Id FROM Account WHERE SourceSystemIdentifier = '114232' LIMIT 1];
        Case awvCase = [SELECT Id, Status, Sub_Status__c FROM Case
            WHERE AccountId = :testAccount.Id AND Type = 'AWV Scheduling' LIMIT 1];
        // Clear both slots and put the case in 'In Progress' to simulate
        // a case PES is actively working when the escalation arrives.
        awvCase.Call_Attempt_1__c = null;
        awvCase.Call_Attempt_2__c = null;
        awvCase.Status = 'In Progress';
        awvCase.Sub_Status__c = 'Left Message';
        update awvCase;

        DateTime callTime = DateTime.now().addMinutes(-5);

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 30200,
                Sequence_Definition_Id__c = SEQ_DEF_AWV,
                External_Patient_Id__c = '114232',
                Status__c = 'ended',
                Outcome__c = 'escalated',
                Ended_Reason__c = 'assistant-ended',
                Was_Contact_Reached__c = true,
                Call_Count__c = 1,
                Call_Started_At__c = callTime,
                Received_At__c = DateTime.now(),
                Summary__c = 'The Assistant transferred the patient to PES because she asked '
                    + 'to speak with the front desk to confirm provider availability.',
                External_Id__c = 'escalated-handoff'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        Case updated = [SELECT Status, Sub_Status__c, Call_Attempt_1__c, Call_Attempt_2__c, Rule_Engine__c
            FROM Case WHERE Id = :awvCase.Id];
        System.assertEquals('In Progress', updated.Status,
            'Escalated handoff must NOT change the case Status');
        System.assertEquals('Left Message', updated.Sub_Status__c,
            'Escalated handoff must NOT change the case Sub_Status');
        System.assertNotEquals(null, updated.Call_Attempt_1__c,
            'Escalated handoff must stamp Call_Attempt_1__c so cadence is exhausted');
        System.assertNotEquals(null, updated.Call_Attempt_2__c,
            'Escalated handoff must stamp Call_Attempt_2__c so cadence is exhausted');
        System.assert(updated.Rule_Engine__c.contains('Escalated to PES'),
            'Rule_Engine__c should record the escalation reason');

        List<CaseComment> comments = [SELECT CommentBody FROM CaseComment WHERE ParentId = :awvCase.Id];
        System.assertEquals(1, comments.size(),
            'Escalated handoff should leave one audit CaseComment');
        System.assert(comments[0].CommentBody.contains('escalated to PES'),
            'CaseComment should describe the escalation');
        System.assert(comments[0].CommentBody.contains('Both attempt slots stamped'),
            'CaseComment should explain why we stamped both slots');
        System.assert(comments[0].CommentBody.contains('transferred the patient to PES'),
            'CaseComment should include the AI summary');
    }

    @isTest
    static void testEscalated_PreservesExistingAttempt1FromPES() {
        // PES already manually logged Attempt 1; escalation arrives. Only
        // Attempt 2 needs stamping; Attempt 1 must be preserved.
        Account testAccount = [SELECT Id FROM Account WHERE SourceSystemIdentifier = '114232' LIMIT 1];
        Case awvCase = [SELECT Id, Call_Attempt_1__c FROM Case
            WHERE AccountId = :testAccount.Id AND Type = 'AWV Scheduling' LIMIT 1];
        DateTime pesAttempt1 = awvCase.Call_Attempt_1__c;
        System.assertNotEquals(null, pesAttempt1, 'Precondition: PES stamped Attempt 1');

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 30201,
                Sequence_Definition_Id__c = SEQ_DEF_AWV,
                External_Patient_Id__c = '114232',
                Status__c = 'ended',
                Outcome__c = 'escalated',
                Ended_Reason__c = 'assistant-ended',
                Was_Contact_Reached__c = true,
                Call_Count__c = 1,
                Call_Started_At__c = DateTime.now().addMinutes(-2),
                Received_At__c = DateTime.now(),
                Summary__c = 'Patient asked to be transferred to a person.',
                External_Id__c = 'escalated-after-pes'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        Case updated = [SELECT Call_Attempt_1__c, Call_Attempt_2__c FROM Case WHERE Id = :awvCase.Id];
        System.assertEquals(pesAttempt1, updated.Call_Attempt_1__c,
            'PES-stamped Attempt 1 must be preserved');
        System.assertNotEquals(null, updated.Call_Attempt_2__c,
            'Attempt 2 must be stamped to mark cadence exhausted');
    }

    @isTest
    static void testAttempt2_PatientReached_DoesNotClose() {
        // Attempt 2: patient picked up and the AI engaged. Even though both
        // slots are now filled, the case should NOT close — patient was
        // reached and PES needs to follow up.
        Account testAccount = [SELECT Id FROM Account WHERE SourceSystemIdentifier = '114232' LIMIT 1];
        Case awvCase = [SELECT Id FROM Case
            WHERE AccountId = :testAccount.Id AND Type = 'AWV Scheduling' LIMIT 1];

        DateTime callTime = DateTime.now().addMinutes(-5);

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 30102,
                Sequence_Definition_Id__c = SEQ_DEF_AWV,
                External_Patient_Id__c = '114232',
                Status__c = 'ended',
                Outcome__c = 'unresolved',
                Ended_Reason__c = 'customer-ended',
                Was_Contact_Reached__c = true,
                Call_Count__c = 1,
                Call_Started_At__c = callTime,
                Received_At__c = DateTime.now(),
                External_Id__c = 'attempt2-reached'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        Case updated = [SELECT Call_Attempt_2__c, Status, Sub_Status__c FROM Case WHERE Id = :awvCase.Id];
        System.assertEquals(callTime, updated.Call_Attempt_2__c, 'Attempt 2 should still be stamped');
        System.assertEquals('In Progress', updated.Status,
            'Patient was reached on attempt 2 — should not close');
        System.assertEquals('Left Message', updated.Sub_Status__c);
    }

    @isTest
    static void testBothSlotsFull_BeforeWebhook_AddsCommentOnly() {
        // Both slots already filled before this webhook. We add an audit
        // CaseComment but do not change the disposition (case is already in
        // its final state per its current Status).
        Account testAccount = [SELECT Id FROM Account WHERE SourceSystemIdentifier = '114232' LIMIT 1];
        Case awvCase = [SELECT Id FROM Case
            WHERE AccountId = :testAccount.Id AND Type = 'AWV Scheduling' LIMIT 1];

        awvCase.Call_Attempt_2__c = DateTime.now().addDays(-1);
        update awvCase;

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 30003,
                Sequence_Definition_Id__c = SEQ_DEF_AWV,
                External_Patient_Id__c = '114232',
                Status__c = 'ended',
                Outcome__c = 'unreachable',
                Ended_Reason__c = 'voicemail',
                Call_Count__c = 1,
                Call_Started_At__c = DateTime.now().addHours(-1),
                Received_At__c = DateTime.now(),
                Summary__c = 'Left voicemail for patient',
                External_Id__c = 'both-full'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        List<CaseComment> comments = [SELECT CommentBody FROM CaseComment WHERE ParentId = :awvCase.Id];
        System.assertEquals(1, comments.size(), 'Should create one audit CaseComment');
        System.assert(comments[0].CommentBody.contains('both attempt slots were already populated'),
            'Comment should describe the both-slots-full audit trail');
    }

    @isTest
    static void testBlended_PESThenAI_Outreach_ClosesWithOneAI_OutreachAttempt() {
        // Blended scenario: a PES staff member already manually logged Attempt 1
        // (which is what setupTestData() simulates on the AWV case). AI_Outreach
        // calls once, leaves a voicemail, fills Attempt 2 → case closes as
        // Unable to Reach. This is the Margaret Venske / Mary Drexler pattern.
        Account testAccount = [SELECT Id FROM Account WHERE SourceSystemIdentifier = '114232' LIMIT 1];
        Case awvCase = [SELECT Id, Call_Attempt_1__c FROM Case
            WHERE AccountId = :testAccount.Id AND Type = 'AWV Scheduling' LIMIT 1];

        DateTime External CallTime = DateTime.now().addMinutes(-30);

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 30010,
                Sequence_Definition_Id__c = SEQ_DEF_AWV,
                External_Patient_Id__c = '114232',
                Status__c = 'ended',
                Outcome__c = 'unreachable',
                Ended_Reason__c = 'voicemail',
                Was_Contact_Reached__c = false,
                Call_Count__c = 1, // AI_Outreach always says 1 — should be ignored
                Call_Started_At__c = External CallTime,
                Received_At__c = DateTime.now(),
                External_Id__c = 'blended'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        Case updated = [SELECT Call_Attempt_1__c, Call_Attempt_2__c, Status, Sub_Status__c
            FROM Case WHERE Id = :awvCase.Id];
        System.assertEquals(awvCase.Call_Attempt_1__c, updated.Call_Attempt_1__c,
            'PES-stamped Attempt 1 should be preserved');
        System.assertEquals(External CallTime, updated.Call_Attempt_2__c,
            'External Call should fill Attempt 2');
        System.assertEquals('Closed', updated.Status,
            'Case should close on blended PES+AI_Outreach attempts');
        System.assertEquals('Unable to Reach', updated.Sub_Status__c);
    }

    @isTest
    static void testNullCallStartedAt_FallsBackToReceivedAt() {
        // Some AI_Outreach lifecycle webhooks omit call_started_at (busy / no-answer
        // calls that never connected). We should still log the attempt using
        // received_at rather than silently dropping the stamp.
        Account testAccount = [SELECT Id FROM Account WHERE SourceSystemIdentifier = '114232' LIMIT 1];
        Case awvCase = [SELECT Id FROM Case
            WHERE AccountId = :testAccount.Id AND Type = 'AWV Scheduling' LIMIT 1];
        awvCase.Call_Attempt_1__c = null;
        awvCase.Status = 'New';
        update awvCase;

        DateTime receivedAt = DateTime.now();

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 30011,
                Sequence_Definition_Id__c = SEQ_DEF_AWV,
                External_Patient_Id__c = '114232',
                Status__c = 'ended',
                Outcome__c = 'unreachable',
                Ended_Reason__c = 'silence-time-out',
                Call_Count__c = 1,
                Call_Started_At__c = null, // missing!
                Received_At__c = receivedAt,
                External_Id__c = 'no-call-started'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        Case updated = [SELECT Call_Attempt_1__c, Status, Sub_Status__c FROM Case WHERE Id = :awvCase.Id];
        System.assertEquals(receivedAt, updated.Call_Attempt_1__c,
            'Attempt 1 should fall back to Received_At__c when Call_Started_At__c is null');
        System.assertEquals('In Progress', updated.Status, 'Status should advance to In Progress');
        System.assertEquals('Left Message', updated.Sub_Status__c,
            'Unreachable on attempt 1 should disposition as Left Message');
    }

    @isTest
    static void testOffCadenceCase_StampedByCampaign217() {
        // A No Next Visit campaign 217 sequence may land on an Off-Cadence case
        // (staff manually moved patient to off-cadence cycle). The handler must
        // recognise Off-Cadence as an eligible Type for campaign 217.
        Id offCadenceAcctRTId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
            .get('PersonAccount').getRecordTypeId();
        Account offCadenceAcct = new Account(
            LastName = 'Off Cadence Patient',
            SourceSystemIdentifier = '115500',
            RecordTypeId = offCadenceAcctRTId
        );
        insert offCadenceAcct;

        Id schedulingRTId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName()
            .get('Scheduling').getRecordTypeId();
        Case offCadenceCase = new Case(
            AccountId = offCadenceAcct.Id,
            RecordTypeId = schedulingRTId,
            Type = 'Off-Cadence',
            Status = 'New',
            Subject = 'Off-Cadence Follow-up'
        );
        insert offCadenceCase;

        DateTime callTime = DateTime.now().addMinutes(-45);

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 30012,
                Sequence_Definition_Id__c = SEQ_DEF_NO_NEXT,
                External_Patient_Id__c = '115500',
                Status__c = 'ended',
                Outcome__c = 'unreachable',
                Ended_Reason__c = 'voicemail',
                Was_Contact_Reached__c = false,
                Call_Count__c = 1,
                Call_Started_At__c = callTime,
                Received_At__c = DateTime.now(),
                External_Id__c = 'off-cadence-stamp'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        Case updated = [SELECT Call_Attempt_1__c, Status, Sub_Status__c
            FROM Case WHERE Id = :offCadenceCase.Id];
        System.assertEquals(callTime, updated.Call_Attempt_1__c,
            'Off-Cadence case should be stamped from campaign 217 webhook');
        System.assertEquals('In Progress', updated.Status,
            'Status should move from New to In Progress on first attempt');
        System.assertEquals('Left Message', updated.Sub_Status__c);
    }

    @isTest
    static void testUnengagedCase_DoesNotChangeStatus() {
        // Cases moved to 'Unengaged' status reflect a deliberate staff decision
        // that the patient is off-cycle. The AI_Outreach webhook must NOT change
        // the disposition — staff decision is sacred.
        Account testAccount = [SELECT Id FROM Account WHERE SourceSystemIdentifier = '114232' LIMIT 1];
        Case awvCase = [SELECT Id FROM Case
            WHERE AccountId = :testAccount.Id AND Type = 'AWV Scheduling' LIMIT 1];
        awvCase.Call_Attempt_1__c = null;
        awvCase.Status = 'Unengaged';
        update awvCase;

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 30013,
                Sequence_Definition_Id__c = SEQ_DEF_AWV,
                External_Patient_Id__c = '114232',
                Status__c = 'ended',
                Outcome__c = 'unreachable',
                Ended_Reason__c = 'voicemail',
                Was_Contact_Reached__c = false,
                Call_Count__c = 1,
                Call_Started_At__c = DateTime.now().addMinutes(-15),
                Received_At__c = DateTime.now(),
                External_Id__c = 'unengaged-no-status-change'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        Case updated = [SELECT Status, Call_Attempt_1__c FROM Case WHERE Id = :awvCase.Id];
        System.assertEquals('Unengaged', updated.Status,
            'Unengaged status must not be overridden by AI_Outreach webhook');
        System.assertNotEquals(null, updated.Call_Attempt_1__c,
            'Attempt 1 should still be stamped for audit even when status is protected');
    }

    // ── DNC Opt-Out Tests ──

    @isTest
    static void testDncOptOut_Outcome() {
        Account dncAccount = [SELECT Id, AI_Outreach_Optout__c FROM Account
            WHERE SourceSystemIdentifier = '114999' LIMIT 1];
        System.assertEquals(false, dncAccount.AI_Outreach_Optout__c, 'Precondition: not opted out');

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 40001,
                Sequence_Definition_Id__c = SEQ_DEF_NO_NEXT,
                External_Patient_Id__c = '114999',
                Status__c = 'ended',
                Outcome__c = 'DNC',
                Call_Count__c = 1,
                Call_Started_At__c = DateTime.now(),
                Received_At__c = DateTime.now(),
                External_Id__c = 'dnc-outcome'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        Account updated = [SELECT AI_Outreach_Optout__c FROM Account WHERE Id = :dncAccount.Id];
        System.assertEquals(true, updated.AI_Outreach_Optout__c,
            'DNC outcome should set AI_Outreach_Optout__c = true');
    }

    @isTest
    static void testDncOptOut_EndedReason() {
        Account dncAccount = [SELECT Id, AI_Outreach_Optout__c FROM Account
            WHERE SourceSystemIdentifier = '114999' LIMIT 1];

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 40002,
                Sequence_Definition_Id__c = SEQ_DEF_NO_NEXT,
                External_Patient_Id__c = '114999',
                Status__c = 'ended',
                Ended_Reason__c = 'Patient requested do_not_call',
                Call_Count__c = 1,
                Call_Started_At__c = DateTime.now(),
                Received_At__c = DateTime.now(),
                External_Id__c = 'dnc-ended-reason'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        Account updated = [SELECT AI_Outreach_Optout__c FROM Account WHERE Id = :dncAccount.Id];
        System.assertEquals(true, updated.AI_Outreach_Optout__c,
            'DNC ended_reason should set AI_Outreach_Optout__c = true');
    }

    // ── No Next Visit Case Resolution ──

    @isTest
    static void testNoNextCase_Attempt2Unreachable_Closes() {
        // No Next case in setup has Attempt 1 populated; webhook fills Attempt 2
        // with an unreachable outcome → case closes as Unable to Reach.
        Account noNextAcct = [SELECT Id FROM Account WHERE SourceSystemIdentifier = '114999' LIMIT 1];
        Case noNextCase = [SELECT Id, Call_Attempt_1__c FROM Case
            WHERE AccountId = :noNextAcct.Id AND Type = 'No Next Visit' LIMIT 1];
        DateTime originalAttempt = noNextCase.Call_Attempt_1__c;

        DateTime realCallTime = DateTime.now().addHours(-4);

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 50001,
                Sequence_Definition_Id__c = SEQ_DEF_NO_NEXT,
                External_Patient_Id__c = '114999',
                Status__c = 'ended',
                Outcome__c = 'unreachable',
                Ended_Reason__c = 'voicemail',
                Was_Contact_Reached__c = false,
                Call_Count__c = 1,
                Call_Started_At__c = realCallTime,
                Received_At__c = DateTime.now(),
                External_Id__c = 'no-next-attempt2-vm'
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        Case updated = [SELECT Call_Attempt_1__c, Call_Attempt_2__c, Status, Sub_Status__c
            FROM Case WHERE Id = :noNextCase.Id];
        System.assertEquals(originalAttempt, updated.Call_Attempt_1__c,
            'Attempt 1 should be preserved');
        System.assertEquals(realCallTime, updated.Call_Attempt_2__c,
            'Attempt 2 should be stamped with the actual call time');
        System.assertEquals('Closed', updated.Status, 'Unreachable on attempt 2 should close');
        System.assertEquals('Unable to Reach', updated.Sub_Status__c);
    }

    // ── isDncResponse Utility ──

    @isTest
    static void testIsDncResponse() {
        System.assertEquals(true, External CallEventHandler.isDncResponse('DNC'));
        System.assertEquals(true, External CallEventHandler.isDncResponse('Patient said do not call'));
        System.assertEquals(true, External CallEventHandler.isDncResponse('do_not_call'));
        System.assertEquals(true, External CallEventHandler.isDncResponse('Patient opted out'));
        System.assertEquals(false, External CallEventHandler.isDncResponse('voicemail'));
        System.assertEquals(false, External CallEventHandler.isDncResponse('completed'));
        System.assertEquals(false, External CallEventHandler.isDncResponse(null));
        System.assertEquals(false, External CallEventHandler.isDncResponse(''));
    }

    // ── Platform Event Trigger Coverage ──

    @isTest
    static void testTrigger_PublishEvent() {
        Test.startTest();

        AI_Outreach_Call_Event__e testEvent = new AI_Outreach_Call_Event__e(
            Sequence_Id__c = 88888,
            Sequence_Definition_Id__c = SEQ_DEF_AWV,
            External_Patient_Id__c = '114232',
            Phone_Number__c = '+17028303827',
            Status__c = 'ended',
            Outcome__c = 'appointment_scheduled',
            Was_Contact_Reached__c = true,
            Call_Count__c = 2,
            Duration_Seconds__c = 180,
            Call_Started_At__c = DateTime.now(),
            Summary__c = 'Patient scheduled AWV appointment',
            External_Id__c = 'trigger-test-uuid',
            Received_At__c = DateTime.now()
        );

        Database.SaveResult sr = EventBus.publish(testEvent);
        System.assertEquals(true, sr.isSuccess(), 'Event should be published successfully');

        Test.getEventBus().deliver();
        Test.stopTest();

        List<AI_Outreach_Call__c> calls = [
            SELECT Id, Sequence_Id__c, Status__c, Outcome__c, Account__c
            FROM AI_Outreach_Call__c WHERE Sequence_Id__c = 88888
        ];

        System.assertEquals(1, calls.size(), 'Trigger should create one External Call record');
        System.assertEquals('ended', calls[0].Status__c);
        System.assertEquals('appointment_scheduled', calls[0].Outcome__c);

        Account testAccount = [SELECT Id FROM Account WHERE SourceSystemIdentifier = '114232' LIMIT 1];
        System.assertEquals(testAccount.Id, calls[0].Account__c);
    }

    // ── Inbound Call Tests ──

    @isTest
    static void testInbound_CreatesCallLinkedByMrn_NoCaseTouch() {
        // Inbound (patient-initiated) call. Must: create a AI_Outreach_Call__c keyed
        // on Call_Id__c (no sequence id), link to the Account by MRN/SSID, tag
        // Direction = Inbound, and NOT stamp the patient's open AWV case.
        Account testAccount = [SELECT Id FROM Account WHERE SourceSystemIdentifier = '114232' LIMIT 1];
        Case awvCase = [SELECT Id, Call_Attempt_1__c, Status FROM Case
            WHERE AccountId = :testAccount.Id AND Type = 'AWV Scheduling' LIMIT 1];
        DateTime originalAttempt1 = awvCase.Call_Attempt_1__c;
        String originalStatus = awvCase.Status;

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Direction__c = 'Inbound',
                Call_Id__c = '20669300',
                External_Patient_Id__c = '114232',
                Phone_Number__c = '+16122712853',
                Status__c = 'ended',
                Outcome__c = 'resolved',
                Was_Contact_Reached__c = true,
                Call_Count__c = 1,
                Duration_Seconds__c = 83,
                Call_Started_At__c = DateTime.now().addMinutes(-5),
                Summary__c = 'Patient confirmed appointment time.',
                Transcript__c = 'AI: How may I help you? User: confirm my appointment.',
                External_Id__c = 'inbound-uuid-1',
                Received_At__c = DateTime.now()
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        List<AI_Outreach_Call__c> calls = [
            SELECT Id, Direction__c, Call_Id__c, Sequence_Id__c, Account__c, Outcome__c
            FROM AI_Outreach_Call__c WHERE Call_Id__c = 20669300
        ];
        System.assertEquals(1, calls.size(), 'Inbound call should create one AI_Outreach_Call__c');
        System.assertEquals('Inbound', calls[0].Direction__c, 'Direction should be Inbound');
        System.assertEquals(20669300, calls[0].Call_Id__c, 'Call_Id should be stored');
        System.assertEquals(null, calls[0].Sequence_Id__c, 'Inbound call has no Sequence Id');
        System.assertEquals(testAccount.Id, calls[0].Account__c,
            'Inbound call should link to Account by MRN/SSID');

        // Critical: the open AWV case must be untouched by an inbound call.
        Case afterCase = [SELECT Call_Attempt_1__c, Status FROM Case WHERE Id = :awvCase.Id];
        System.assertEquals(originalAttempt1, afterCase.Call_Attempt_1__c,
            'Inbound call must NOT stamp the AWV case attempt slot');
        System.assertEquals(originalStatus, afterCase.Status,
            'Inbound call must NOT change the AWV case status');
    }

    @isTest
    static void testInbound_NoMatch_LoadsUnlinked() {
        // Inbound call with no resolvable patient (no MRN match). Should still
        // create the AI_Outreach_Call__c with a null Account.
        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Direction__c = 'Inbound',
                Call_Id__c = '20669301',
                External_Patient_Id__c = null,
                Status__c = 'ended',
                Outcome__c = 'unresolved',
                Summary__c = 'Anonymous inbound caller.',
                Received_At__c = DateTime.now()
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        AI_Outreach_Call__c call = [SELECT Id, Direction__c, Account__c
            FROM AI_Outreach_Call__c WHERE Call_Id__c = 20669301];
        System.assertEquals('Inbound', call.Direction__c);
        System.assertEquals(null, call.Account__c, 'Unmatched inbound call should be unlinked');
    }

    @isTest
    static void testInbound_DncSetsOptOut() {
        // A patient who says "do not call" on an inbound call must still be
        // flagged for opt-out even though inbound skips Case processing.
        Account dncAccount = [SELECT Id, AI_Outreach_Optout__c FROM Account
            WHERE SourceSystemIdentifier = '114999' LIMIT 1];
        System.assertEquals(false, dncAccount.AI_Outreach_Optout__c, 'Precondition: not opted out');

        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Direction__c = 'Inbound',
                Call_Id__c = '20669302',
                External_Patient_Id__c = '114999',
                Status__c = 'ended',
                Outcome__c = 'resolved',
                Ended_Reason__c = 'Patient requested do_not_call',
                Received_At__c = DateTime.now()
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        Account updated = [SELECT AI_Outreach_Optout__c FROM Account WHERE Id = :dncAccount.Id];
        System.assertEquals(true, updated.AI_Outreach_Optout__c,
            'DNC on inbound call should set AI_Outreach_Optout__c = true');
    }

    @isTest
    static void testOutbound_DefaultsDirectionOutbound() {
        // An outbound event with no Direction__c set must default to Outbound.
        List<AI_Outreach_Call_Event__e> events = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Sequence_Id__c = 61000,
                Sequence_Definition_Id__c = SEQ_DEF_AWV,
                External_Patient_Id__c = '114232',
                Status__c = 'ended',
                Outcome__c = 'unreachable',
                Received_At__c = DateTime.now()
            )
        };

        Test.startTest();
        External CallEventHandler.handleEvents(events);
        Test.stopTest();

        AI_Outreach_Call__c call = [SELECT Direction__c FROM AI_Outreach_Call__c WHERE Sequence_Id__c = 61000];
        System.assertEquals('Outbound', call.Direction__c,
            'Events without Direction should default to Outbound');
    }

    @isTest
    static void testInbound_UpsertOnCallId_NoDuplicate() {
        // Re-processing the same inbound Call_Id must upsert, not duplicate.
        List<AI_Outreach_Call_Event__e> first = new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Direction__c = 'Inbound', Call_Id__c = '20669303',
                External_Patient_Id__c = '114232', Status__c = 'ended',
                Outcome__c = 'resolved', Received_At__c = DateTime.now()
            )
        };
        Test.startTest();
        External CallEventHandler.handleEvents(first);
        External CallEventHandler.handleEvents(new List<AI_Outreach_Call_Event__e>{
            new AI_Outreach_Call_Event__e(
                Direction__c = 'Inbound', Call_Id__c = '20669303',
                External_Patient_Id__c = '114232', Status__c = 'ended',
                Outcome__c = 'unresolved', Received_At__c = DateTime.now()
            )
        });
        Test.stopTest();

        List<AI_Outreach_Call__c> calls = [SELECT Id, Outcome__c
            FROM AI_Outreach_Call__c WHERE Call_Id__c = 20669303];
        System.assertEquals(1, calls.size(), 'Re-processing same Call_Id should not duplicate');
        System.assertEquals('unresolved', calls[0].Outcome__c, 'Second event should update outcome');
    }

    @isTest
    static void testIsInboundEvent() {
        System.assertEquals(true, External CallEventHandler.isInboundEvent(
            new AI_Outreach_Call_Event__e(Direction__c = 'Inbound')));
        System.assertEquals(true, External CallEventHandler.isInboundEvent(
            new AI_Outreach_Call_Event__e(Direction__c = 'inbound')));
        System.assertEquals(false, External CallEventHandler.isInboundEvent(
            new AI_Outreach_Call_Event__e(Direction__c = 'Outbound')));
        System.assertEquals(false, External CallEventHandler.isInboundEvent(
            new AI_Outreach_Call_Event__e(Direction__c = null)));
    }
}
