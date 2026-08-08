@IsTest
private class External CallCareItemReconcileBatchTest {
  static Id personRt() {
    for (RecordType rt : [
      SELECT Id FROM RecordType
      WHERE SObjectType = 'Account' AND IsPersonType = true
      LIMIT 1
    ])
      return rt.Id;
    return null;
  }

  static Account mkAccount(String last) {
    Account a = new Account(LastName = last);
    Id rt = personRt();
    if (rt != null) a.RecordTypeId = rt;
    insert a;
    return a;
  }

  static Patient_Need__c mkNeed(
    Id acctId,
    String needType,
    String ruleId,
    String suffix,
    String state
  ) {
    Patient_Need__c need = new Patient_Need__c(
      Patient__c = acctId,
      Need_Type__c = needType,
      Rule_Id__c = ruleId,
      Rule_Version__c = '1',
      Engine_Key__c = String.valueOf(acctId) + ':' + ruleId + ':1-' + suffix,
      State__c = state,
      Priority__c = 'Routine',
      Points__c = 10,
      Shadow__c = false,
      Next_Action_Date__c = Date.today()
    );
    insert need;
    return need;
  }

  static Patient_Need__c mkNeed(Id acctId, String needType, String ruleId, String suffix) {
    return mkNeed(acctId, needType, ruleId, suffix, 'Pending');
  }

  @IsTest
  static void flipsLegacyAI_OutreachPhoneToAI_Outreach() {
    Account a = mkAccount('FlipLegacyAI_Outreach');
    Datetime at = System.now().addDays(-4);
    AI_Outreach_Call__c call = new AI_Outreach_Call__c(
      Account__c = a.Id,
      Sequence_Definition_Id__c = 217,
      Sequence_Id__c = 888001,
      Outcome__c = 'unreachable',
      Call_Started_At__c = at,
      Status__c = 'completed',
      Direction__c = 'Outbound'
    );
    insert call;

    Patient_Need__c need = mkNeed(a.Id, 'NO_NEXT', 'NO_NEXT_FOLLOWUP', 'fl');
    String key = 'legacy-ai_outreach:' + String.valueOf(call.Id);
    insert new Outreach_Event__c(
      Patient__c = a.Id,
      Need__c = need.Id,
      Event_Type__c = 'Attempt Made',
      Channel__c = 'Phone',
      Outcome__c = 'Left Message',
      Detail__c = 'Mislabelled AI_Outreach backfill',
      Event_At__c = at,
      Idempotency_Key__c = key,
      Shadow__c = false
    );

    Test.startTest();
    Database.executeBatch(new External CallCareItemReconcileBatch(), 50);
    Test.stopTest();

    Outreach_Event__c afterEvt = [
      SELECT Channel__c, Detail__c FROM Outreach_Event__c WHERE Idempotency_Key__c = :key
    ];
    System.assertEquals('AI_Outreach', afterEvt.Channel__c);
    System.assert(afterEvt.Detail__c.contains('campaign 217'));
  }

  @IsTest
  static void reclassifiesNearPhoneWithoutDuplicate() {
    Account a = mkAccount('NearPhoneReclass');
    Datetime at = System.now().addDays(-6);
    AI_Outreach_Call__c call = new AI_Outreach_Call__c(
      Account__c = a.Id,
      Sequence_Definition_Id__c = 178,
      Sequence_Id__c = 888002,
      Outcome__c = 'resolved',
      Call_Started_At__c = at,
      Status__c = 'completed',
      Direction__c = 'Outbound'
    );
    insert call;

    Patient_Need__c need = mkNeed(a.Id, 'AWV', 'AWV_DUE', 'np');
    insert new Outreach_Event__c(
      Patient__c = a.Id,
      Need__c = need.Id,
      Event_Type__c = 'Attempt Made',
      Channel__c = 'Phone',
      Outcome__c = 'Left Message',
      Detail__c = 'Case slot backfill',
      Event_At__c = at.addSeconds(45),
      Idempotency_Key__c = 'legacy-case:fake:attempt1-' + String.valueOf(need.Id),
      Shadow__c = false
    );

    Test.startTest();
    Database.executeBatch(new External CallCareItemReconcileBatch(), 50);
    Test.stopTest();

    List<Outreach_Event__c> evts = [
      SELECT Channel__c, Idempotency_Key__c
      FROM Outreach_Event__c
      WHERE Need__c = :need.Id AND Event_Type__c = 'Attempt Made'
    ];
    System.assertEquals(1, evts.size(), 'Must not duplicate');
    System.assertEquals('AI_Outreach', evts[0].Channel__c);
  }

  @IsTest
  static void skipsInboundCalls() {
    Account a = mkAccount('InboundSkip');
    AI_Outreach_Call__c call = new AI_Outreach_Call__c(
      Account__c = a.Id,
      Sequence_Definition_Id__c = 217,
      Sequence_Id__c = 888003,
      Outcome__c = 'resolved',
      Call_Started_At__c = System.now().addDays(-2),
      Status__c = 'completed',
      Direction__c = 'Inbound'
    );
    insert call;
    Patient_Need__c need = mkNeed(a.Id, 'NO_NEXT', 'NO_NEXT_FOLLOWUP', 'in');

    Test.startTest();
    Database.executeBatch(new External CallCareItemReconcileBatch(), 50);
    Test.stopTest();

    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Outreach_Event__c
        WHERE Need__c = :need.Id AND Event_Type__c = 'Attempt Made'
      ],
      'Inbound must not create campaign outreach attempts'
    );
  }

  @IsTest
  static void insertsWhenNoNearAttempt() {
    Account a = mkAccount('InsertOutbound');
    AI_Outreach_Call__c call = new AI_Outreach_Call__c(
      Account__c = a.Id,
      Sequence_Definition_Id__c = 217,
      Sequence_Id__c = 888004,
      Outcome__c = 'unreachable',
      Call_Started_At__c = System.now().addDays(-1),
      Status__c = 'completed',
      Direction__c = 'Outbound'
    );
    insert call;
    Patient_Need__c need = mkNeed(a.Id, 'NO_NEXT', 'NO_NEXT_FOLLOWUP', 'ins');

    Test.startTest();
    Database.executeBatch(new External CallCareItemReconcileBatch(), 50);
    Test.stopTest();

    List<Outreach_Event__c> evts = [
      SELECT Channel__c, Idempotency_Key__c
      FROM Outreach_Event__c
      WHERE Need__c = :need.Id AND Event_Type__c = 'Attempt Made'
    ];
    System.assertEquals(1, evts.size());
    System.assertEquals('AI_Outreach', evts[0].Channel__c);
    System.assert(evts[0].Idempotency_Key__c.startsWith('legacy-ai_outreach:'));
  }

  @IsTest
  static void skipsWhenOnlyResolvedNeed() {
    Account a = mkAccount('ResolvedGate');
    AI_Outreach_Call__c call = new AI_Outreach_Call__c(
      Account__c = a.Id,
      Sequence_Definition_Id__c = 217,
      Sequence_Id__c = 888005,
      Outcome__c = 'unreachable',
      Call_Started_At__c = System.now().addDays(-1),
      Status__c = 'completed',
      Direction__c = 'Outbound'
    );
    insert call;
    Patient_Need__c need = mkNeed(
      a.Id,
      'NO_NEXT',
      'NO_NEXT_FOLLOWUP',
      'res',
      'Resolved'
    );
    need.Resolution_Reason__c = 'Max attempts reached';
    update need;

    Test.startTest();
    Database.executeBatch(new External CallCareItemReconcileBatch(), 50);
    Test.stopTest();

    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Outreach_Event__c
        WHERE Need__c = :need.Id AND Event_Type__c = 'Attempt Made'
      ],
      'Resolved-only Need must block reconcile insert (active-Need gate)'
    );
  }

}
