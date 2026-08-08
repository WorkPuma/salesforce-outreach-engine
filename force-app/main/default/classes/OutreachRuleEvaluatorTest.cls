@IsTest
private class OutreachRuleEvaluatorTest {
  private static Account accountWith(Map<String, Object> values) {
    Map<String, Object> payload = new Map<String, Object>{
      'attributes' => new Map<String, Object>{ 'type' => 'Account' }
    };
    payload.putAll(values);
    return (Account) JSON.deserialize(JSON.serialize(payload), Account.class);
  }
  @IsTest
  static void expiredSnoozeWakesAndClearsDate() {
    Patient_Need__c expired = new Patient_Need__c(
      State__c = 'Snoozed',
      Snooze_Until__c = System.now().addMinutes(-1)
    );
    Patient_Need__c evaluated = new Patient_Need__c();
    OutreachRuleEvaluator.applyPreservedState(evaluated, expired, false);
    System.assertEquals('Pending', evaluated.State__c);
    System.assertEquals(null, evaluated.Snooze_Until__c);

    Patient_Need__c future = new Patient_Need__c(
      State__c = 'Snoozed',
      Snooze_Until__c = System.now().addDays(1)
    );
    evaluated = new Patient_Need__c();
    OutreachRuleEvaluator.applyPreservedState(evaluated, future, false);
    System.assertEquals('Snoozed', evaluated.State__c);
    System.assertEquals(future.Snooze_Until__c, evaluated.Snooze_Until__c);
  }

  @IsTest
  static void applyFamilySupersedenceHidesNoNext() {
    List<Outreach_Rule__mdt> rules = new List<Outreach_Rule__mdt>{
      new Outreach_Rule__mdt(
        Rule_Id__c = 'UNENGAGED_6_MONTH',
        Need_Type__c = 'UNENGAGED',
        Family__c = 'UNENGAGED',
        Supersedes_Families__c = 'NO_NEXT'
      ),
      new Outreach_Rule__mdt(
        Rule_Id__c = 'NO_NEXT_FOLLOWUP',
        Need_Type__c = 'NO_NEXT',
        Family__c = 'NO_NEXT',
        Supersedes_Families__c = ''
      )
    };
    Id patientId = '001000000000001AAA';
    List<Patient_Need__c> writes = new List<Patient_Need__c>{
      new Patient_Need__c(
        Patient__c = patientId,
        Rule_Id__c = 'UNENGAGED_6_MONTH',
        Need_Type__c = 'UNENGAGED',
        State__c = 'Pending',
        Engine_Key__c = patientId + ':UNENGAGED_6_MONTH:1'
      ),
      new Patient_Need__c(
        Patient__c = patientId,
        Rule_Id__c = 'NO_NEXT_FOLLOWUP',
        Need_Type__c = 'NO_NEXT',
        State__c = 'Pending',
        Engine_Key__c = patientId + ':NO_NEXT_FOLLOWUP:1'
      )
    };
    OutreachRuleEvaluator.applyFamilySupersedence(writes, rules);
    System.assertEquals('Pending', writes[0].State__c);
    System.assertEquals('Superseded', writes[1].State__c);
  }
  @IsTest
  static void sameFamilyKeepsHighestWeight() {
    List<Outreach_Rule__mdt> rules = new List<Outreach_Rule__mdt>{
      new Outreach_Rule__mdt(
        Rule_Id__c = 'UNENGAGED_6_MONTH',
        Need_Type__c = 'UNENGAGED',
        Family__c = 'UNENGAGED',
        Supersedes_Families__c = 'NO_NEXT'
      ),
      new Outreach_Rule__mdt(
        Rule_Id__c = 'UNENGAGED_OFF_CADENCE',
        Need_Type__c = 'UNENGAGED',
        Family__c = 'UNENGAGED',
        Supersedes_Families__c = 'NO_NEXT'
      )
    };
    Id patientId = '001000000000001AAA';
    List<Patient_Need__c> writes = new List<Patient_Need__c>{
      new Patient_Need__c(
        Patient__c = patientId,
        Rule_Id__c = 'UNENGAGED_6_MONTH',
        Need_Type__c = 'UNENGAGED',
        State__c = 'Pending',
        Points__c = 80,
        Engine_Key__c = patientId + ':UNENGAGED_6_MONTH:1'
      ),
      new Patient_Need__c(
        Patient__c = patientId,
        Rule_Id__c = 'UNENGAGED_OFF_CADENCE',
        Need_Type__c = 'UNENGAGED',
        State__c = 'Pending',
        Points__c = 70,
        Engine_Key__c = patientId + ':UNENGAGED_OFF_CADENCE:1'
      )
    };
    OutreachRuleEvaluator.applyFamilySupersedence(writes, rules);
    System.assertEquals('Pending', writes[0].State__c);
    System.assertEquals('Superseded', writes[1].State__c);
  }
  @IsTest
  static void activeNeedPreservesAttemptsAndShadowCycleResets() {
    Patient_Need__c active = new Patient_Need__c(
      State__c = 'In Progress',
      Attempt_Count__c = 1
    );
    Patient_Need__c evaluated = new Patient_Need__c();
    OutreachRuleEvaluator.applyPreservedState(evaluated, active, false);
    System.assertEquals('In Progress', evaluated.State__c);
    System.assertEquals(1, evaluated.Attempt_Count__c);

    Patient_Need__c priorCycle = new Patient_Need__c(
      State__c = 'Resolved',
      Attempt_Count__c = 2,
      Resolution_Reason__c = 'Appointment Scheduled'
    );
    evaluated = new Patient_Need__c();
    OutreachRuleEvaluator.applyPreservedState(evaluated, priorCycle, true);
    System.assertEquals('Shadow', evaluated.State__c);
    System.assertEquals(0, evaluated.Attempt_Count__c);

    evaluated = new Patient_Need__c();
    OutreachRuleEvaluator.applyPreservedState(evaluated, null, false);
    System.assertEquals('Pending', evaluated.State__c);
  }

  @IsTest
  static void exhaustedNeedStaysClosedUntilEligibilityGap() {
    Patient_Need__c exhausted = new Patient_Need__c(
      State__c = 'Resolved',
      Attempt_Count__c = 2,
      Resolution_Reason__c = 'Max attempts reached'
    );
    Patient_Need__c evaluated = new Patient_Need__c(
      Next_Action_Date__c = Date.today()
    );
    OutreachRuleEvaluator.applyPreservedState(evaluated, exhausted, false);
    System.assertEquals('Resolved', evaluated.State__c);
    System.assertEquals(2, evaluated.Attempt_Count__c);
    System.assertEquals(null, evaluated.Next_Action_Date__c);

    Patient_Need__c returned = new Patient_Need__c(
      State__c = 'Resolved',
      Attempt_Count__c = 2,
      Resolution_Reason__c = 'Appointment Scheduled'
    );
    evaluated = new Patient_Need__c();
    OutreachRuleEvaluator.applyPreservedState(evaluated, returned, false);
    System.assertEquals('Pending', evaluated.State__c);
    System.assertEquals(0, evaluated.Attempt_Count__c);
    System.assertEquals(Date.today(), evaluated.Next_Action_Date__c);
  }

  @IsTest
  static void evaluateViaRulesEngineCreatesNeeds() {
    OutreachRulesEngineClient.settingsOverride = new OutreachRulesEngineClient.Settings();
    OutreachRulesEngineClient.settingsOverride.enabled = true;
    OutreachRulesEngineClient.settingsOverride.projectSlug = 'patient-outreach';
    OutreachRulesEngineClient.settingsOverride.surfaceKey = 'outreach-surface';
    OutreachRulesEngineClient.settingsOverride.reactionKey = 'outreach-reaction';
    OutreachRulesEngineClient.settingsOverride.namedCredential = 'RulesEngine_Agent';
    OutreachRulesEngineClient.settingsOverride.batchSize = 20;
    OutreachRulesEngineClient.mockSurfaceJson =
      '{"result":[{"eligible":true,"ruleId":"AWV_DUE","family":"AWV","needType":"AWV","category":"Scheduling","priority":"Routine","points":60,"shadowOnly":false,"createWork":true,"scheduleBoundType":"ANYTIME_AFTER","scheduleEarliest":"2020-01-01","statusLabel":"Due for an AWV"}]}';

    Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
      .get('PersonAccount')
      .getRecordTypeId();
    Account a = new Account(
      LastName = 'RulesEngine EvalTest',
      RecordTypeId = rt,
      SourceSystemIdentifier = 'RULESENGINE-EVAL-1'
    );
    insert a;

    Test.startTest();
    List<Patient_Need__c> needs = OutreachRuleEvaluator.evaluate(new Set<Id>{ a.Id });
    Test.stopTest();
    Boolean found = false;
    for (Patient_Need__c n : [
      SELECT
        Rule_Id__c,
        Need_Type__c,
        Priority__c,
        Points__c,
        Eligibility_Snapshot__c,
        Schedule_Bound_Type__c,
        Schedule_Earliest__c,
        Schedule_Status_Label__c
      FROM Patient_Need__c
      WHERE Patient__c = :a.Id
    ]) {
      if (n.Rule_Id__c == 'AWV_DUE') {
        found = true;
        System.assert(n.Eligibility_Snapshot__c != null && n.Eligibility_Snapshot__c.contains('RULESENGINE'));
        System.assertEquals('Routine', n.Priority__c);
        System.assertEquals(60, n.Points__c);
        System.assertEquals('ANYTIME_AFTER', n.Schedule_Bound_Type__c);
        System.assertEquals(Date.today(), n.Schedule_Earliest__c); // past earliest clamped
        System.assertEquals('Due for an AWV', n.Schedule_Status_Label__c);
      }
    }
    System.assertEquals(true, found, 'Expected AWV_DUE need from RulesEngine surface');
  }

  @IsTest
  static void evaluateViaRulesEngineClosesUnmatched() {
    OutreachRulesEngineClient.settingsOverride = new OutreachRulesEngineClient.Settings();
    OutreachRulesEngineClient.settingsOverride.enabled = true;
    OutreachRulesEngineClient.settingsOverride.projectSlug = 'patient-outreach';
    OutreachRulesEngineClient.settingsOverride.surfaceKey = 'outreach-surface';
    OutreachRulesEngineClient.settingsOverride.reactionKey = 'outreach-reaction';
    OutreachRulesEngineClient.settingsOverride.namedCredential = 'RulesEngine_Agent';
    OutreachRulesEngineClient.settingsOverride.batchSize = 20;
    OutreachRulesEngineClient.mockSurfaceJson = '{"result":[]}';

    Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
      .get('PersonAccount')
      .getRecordTypeId();
    Account a = new Account(
      LastName = 'RulesEngine CloseTest',
      RecordTypeId = rt,
      SourceSystemIdentifier = 'RULESENGINE-CLOSE-1'
    );
    insert a;
    insert new Patient_Need__c(
      Engine_Key__c = a.Id + ':AWV_DUE:1',
      Patient__c = a.Id,
      Rule_Id__c = 'AWV_DUE',
      Rule_Version__c = '1',
      Need_Type__c = 'AWV',
      State__c = 'Pending',
      Priority__c = 'Urgent',
      Points__c = 70,
      Next_Action_Date__c = Date.today()
    );

    Test.startTest();
    OutreachRuleEvaluator.evaluate(new Set<Id>{ a.Id });
    Test.stopTest();
    Patient_Need__c n = [
      SELECT State__c, Resolution_Reason__c
      FROM Patient_Need__c
      WHERE Patient__c = :a.Id
      LIMIT 1
    ];
    System.assertEquals('Resolved', n.State__c);
    System.assert(
      n.Resolution_Reason__c != null &&
        n.Resolution_Reason__c.contains('RulesEngine')
    );
  }

  @IsTest
  static void evaluateViaRulesEngineRequiresPriorityAndPoints() {
    OutreachRulesEngineClient.settingsOverride = new OutreachRulesEngineClient.Settings();
    OutreachRulesEngineClient.settingsOverride.enabled = true;
    OutreachRulesEngineClient.settingsOverride.projectSlug = 'patient-outreach';
    OutreachRulesEngineClient.settingsOverride.surfaceKey = 'outreach-surface';
    OutreachRulesEngineClient.settingsOverride.reactionKey = 'outreach-reaction';
    OutreachRulesEngineClient.settingsOverride.namedCredential = 'RulesEngine_Agent';
    OutreachRulesEngineClient.settingsOverride.batchSize = 20;
    OutreachRulesEngineClient.mockSurfaceJson =
      '{"result":[{"eligible":true,"ruleId":"AWV_DUE","family":"AWV","needType":"AWV","category":"Scheduling","shadowOnly":false,"createWork":true}]}';

    Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
      .get('PersonAccount')
      .getRecordTypeId();
    Account a = new Account(
      LastName = 'RulesEngine MissingPri',
      RecordTypeId = rt,
      SourceSystemIdentifier = 'RULESENGINE-EVAL-MISS'
    );
    insert a;

    Boolean threw = false;
    try {
      Test.startTest();
      OutreachRuleEvaluator.evaluate(new Set<Id>{ a.Id });
      Test.stopTest();
    } catch (OutreachRulesEngineClient.RulesEngineException ex) {
      threw = true;
      System.assert(ex.getMessage().contains('priority and points'));
    }
    System.assertEquals(true, threw, 'Missing RulesEngine priority/points must fail closed');
  }


  @IsTest
  static void applyScheduleOffsetFromLastCompletedVisit() {
    // Past cadence ends stay as the true window end (not clamped to today)
    // so PES guidance can show the real on-cadence date.
    System.assertEquals(
      Date.newInstance(2020, 2, 15),
      OutreachRuleEvaluator.computeScheduleLatestFromOffset(
        new Map<String, Object>{ 'lastCompletedVisitDate' => '2020-01-01' },
        45
      )
    );
    Date base = Date.today().addDays(-10);
    String iso =
      String.valueOf(base.year()) + '-' +
      (base.month() < 10 ? '0' : '') + String.valueOf(base.month()) + '-' +
      (base.day() < 10 ? '0' : '') + String.valueOf(base.day());
    System.assertEquals(
      base.addDays(23),
      OutreachRuleEvaluator.computeScheduleLatestFromOffset(
        new Map<String, Object>{ 'lastCompletedVisitDate' => iso },
        23
      )
    );
  }

}
