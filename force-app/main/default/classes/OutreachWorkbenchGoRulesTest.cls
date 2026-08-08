@IsTest
private class OutreachWorkbenchRulesEngineTest {
  private static void enableRulesEngine() {
    OutreachRulesEngineClient.settingsOverride = new OutreachRulesEngineClient.Settings();
    OutreachRulesEngineClient.settingsOverride.enabled = true;
    OutreachRulesEngineClient.settingsOverride.projectSlug = 'patient-outreach';
    OutreachRulesEngineClient.settingsOverride.surfaceKey = 'outreach-surface';
    OutreachRulesEngineClient.settingsOverride.reactionKey = 'outreach-reaction';
    OutreachRulesEngineClient.settingsOverride.namedCredential = 'RulesEngine_Agent';
    OutreachRulesEngineClient.settingsOverride.batchSize = 20;
  }

  private static Account patient() {
    Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
      .get('PersonAccount')
      .getRecordTypeId();
    Account a = new Account(
      LastName = 'RulesEngine WB',
      RecordTypeId = rt,
      SourceSystemIdentifier = 'RULESENGINE-WB-1'
    );
    insert a;
    return a;
  }

  @IsTest
  static void reactionSnoozeAndSuppress() {
    enableRulesEngine();
    Account a = patient();
    Patient_Need__c need = new Patient_Need__c(
      Engine_Key__c = a.Id + ':AWV_DUE:1',
      Patient__c = a.Id,
      Rule_Id__c = 'AWV_DUE',
      Rule_Version__c = '1',
      Need_Type__c = 'AWV',
      State__c = 'Pending',
      Priority__c = 'Urgent',
      Points__c = 70,
      Attempt_Count__c = 1,
      Next_Action_Date__c = Date.today()
    );
    insert need;
    OutreachRulesEngineClient.mockReactionJson =
      '{"result":{"suppressDays":30,"snoozeDays":30,"resolve":false,"suppressFamily":"AWV","reason":"Attempt cadence"}}';
    Test.startTest();
    OutreachWorkbenchController.applyAttemptCadence(
      need,
      null,
      'Left Message'
    );
    Test.stopTest();
    System.assertEquals('Snoozed', need.State__c);
    System.assertNotEquals(null, need.Snooze_Until__c);
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Suppression__c
        WHERE Patient__c = :a.Id AND Need_Type__c = 'AWV' AND Active__c = TRUE
      ]
    );
  }

  @IsTest
  static void reactionResolve() {
    enableRulesEngine();
    Account a = patient();
    Patient_Need__c need = new Patient_Need__c(
      Engine_Key__c = a.Id + ':AWV_DUE:2',
      Patient__c = a.Id,
      Rule_Id__c = 'AWV_DUE',
      Rule_Version__c = '1',
      Need_Type__c = 'AWV',
      State__c = 'Pending',
      Priority__c = 'Urgent',
      Points__c = 70,
      Attempt_Count__c = 2,
      Next_Action_Date__c = Date.today()
    );
    insert need;
    OutreachRulesEngineClient.mockReactionJson =
      '{"result":{"suppressDays":0,"snoozeDays":0,"resolve":true,"suppressFamily":"AWV","reason":"Appointment Scheduled"}}';
    Test.startTest();
    OutreachWorkbenchController.applyAttemptCadence(
      need,
      null,
      'Appointment Scheduled'
    );
    Test.stopTest();
    System.assertEquals('Resolved', need.State__c);
    System.assertEquals('Appointment Scheduled', need.Resolution_Reason__c);
  }

  @IsTest
  static void reactionRefusedSuppresses90Days() {
    enableRulesEngine();
    Account a = patient();
    Patient_Need__c need = new Patient_Need__c(
      Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:2',
      Patient__c = a.Id,
      Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Pending',
      Priority__c = 'Routine',
      Points__c = 40,
      Attempt_Count__c = 1,
      Next_Action_Date__c = Date.today()
    );
    insert need;
    OutreachRulesEngineClient.mockReactionJson =
      '{"result":{"suppressDays":90,"snoozeDays":90,"resolve":true,"suppressFamily":"NO_NEXT","reason":"Patient Refused"}}';
    Test.startTest();
    OutreachWorkbenchController.applyAttemptCadence(
      need,
      null,
      'Patient Refused Scheduling'
    );
    Test.stopTest();
    System.assertEquals('Resolved', need.State__c);
    System.assertEquals(Date.today().addDays(90), need.Next_Action_Date__c);
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Suppression__c
        WHERE
          Patient__c = :a.Id
          AND Need_Type__c = 'NO_NEXT'
          AND Active__c = TRUE
          AND Expires_On__c = :Date.today().addDays(90)
      ]
    );
  }



  @IsTest
  static void scheduleClauseForClampsPastAnytimeAfter() {
    OutreachWorkbenchController.NeedDTO past = new OutreachWorkbenchController.NeedDTO();
    past.scheduleBoundType = 'ANYTIME_AFTER';
    past.scheduleEarliest = Date.today().addDays(-30);
    String clause = OutreachWorkbenchController.scheduleClauseFor(past);
    System.assert(
      clause != null && clause.contains('as soon as possible'),
      clause
    );

    OutreachWorkbenchController.NeedDTO future = new OutreachWorkbenchController.NeedDTO();
    future.scheduleBoundType = 'ANYTIME_AFTER';
    future.scheduleEarliest = Date.today().addDays(45);
    String futureClause = OutreachWorkbenchController.scheduleClauseFor(future);
    System.assert(
      futureClause != null && futureClause.contains('anytime after'),
      futureClause
    );

    OutreachWorkbenchController.NeedDTO cadencePast = new OutreachWorkbenchController.NeedDTO();
    cadencePast.scheduleBoundType = 'ON_OR_BEFORE';
    cadencePast.scheduleLatest = Date.today().addDays(-5);
    String pastCadence = OutreachWorkbenchController.scheduleClauseFor(
      cadencePast,
      'Low Risk'
    );
    System.assert(
      pastCadence != null &&
        pastCadence.contains('before') &&
        pastCadence.contains('[Risk Tier: Low]'),
      pastCadence
    );

    OutreachWorkbenchController.NeedDTO cadenceFuture = new OutreachWorkbenchController.NeedDTO();
    cadenceFuture.scheduleBoundType = 'ON_OR_BEFORE';
    cadenceFuture.scheduleLatest = Date.today().addDays(20);
    String futureCadence = OutreachWorkbenchController.scheduleClauseFor(
      cadenceFuture,
      'Rising Risk'
    );
    System.assert(
      futureCadence != null &&
        futureCadence.contains('before') &&
        futureCadence.contains('[Risk Tier: Rising]'),
      futureCadence
    );
  }

}
