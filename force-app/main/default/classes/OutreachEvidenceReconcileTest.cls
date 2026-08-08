@IsTest
private class OutreachEvidenceReconcileTest {
  private static Account patient(String suffix) {
    Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
      .get('PersonAccount')
      .getRecordTypeId();
    Account a = new Account(
      LastName = 'EvRec ' + suffix,
      RecordTypeId = rt,
      SourceSystemIdentifier = 'EVREC-' + suffix
    );
    insert a;
    return a;
  }

  private static Patient_Need__c need(Account a, String state) {
    Patient_Need__c n = new Patient_Need__c(
      Engine_Key__c = a.Id + ':AWV_DUE:1:' + state,
      Patient__c = a.Id,
      Rule_Id__c = 'AWV_DUE',
      Rule_Version__c = '1',
      Need_Type__c = 'AWV',
      State__c = state,
      Priority__c = 'Routine',
      Points__c = 10
    );
    insert n;
    return n;
  }

  private static Outreach_Event__c scheduledEvent(
    Account a,
    Patient_Need__c n,
    Datetime at
  ) {
    Outreach_Event__c e = new Outreach_Event__c(
      Patient__c = a.Id,
      Need__c = n.Id,
      Rule_Id__c = 'AWV_DUE',
      Event_Type__c = 'Appointment Scheduled',
      Outcome__c = 'Appointment Scheduled',
      Channel__c = 'Phone',
      Detail__c = 'Test schedule',
      Actor__c = UserInfo.getUserId(),
      Event_At__c = at,
      Idempotency_Key__c = a.Id + ':ApptSched:' + String.valueOf(at.getTime())
    );
    insert e;
    return e;
  }

  @IsTest
  static void matchesAppointmentInWindow() {
    Account a = patient('match');
    Patient_Need__c n = need(a, 'Resolved');
    Datetime at = System.now().addHours(-2);
    Outreach_Event__c e = scheduledEvent(a, n, at);
    insert new Appointment__c(
      Patient__c = a.Id,
      Start_Date_Time__c = at.addHours(1),
      Status__c = 'Scheduled',
      Type__c = 'Annual Wellness Visit',
      Athena_Appointment_Id__c = 'EVREC-MATCH-1'
    );

    Test.startTest();
    Database.executeBatch(new OutreachEvidenceReconcileBatch(), 50);
    Test.stopTest();

    Outreach_Evidence_Link__c link = [
      SELECT Reconcile_Status__c, Appointment__c, Match_Kind__c
      FROM Outreach_Evidence_Link__c
      WHERE Outreach_Event__c = :e.Id
    ];
    System.assertEquals('Matched', link.Reconcile_Status__c);
    System.assertNotEquals(null, link.Appointment__c);
    System.assertEquals('Appointment', link.Match_Kind__c);
    System.assertEquals(
      'Resolved',
      [SELECT State__c FROM Patient_Need__c WHERE Id = :n.Id].State__c
    );
  }

  @IsTest
  static void unmatchedPastGraceReopensNeed() {
    Account a = patient('reopen');
    Patient_Need__c n = need(a, 'Resolved');
    Datetime at = System.now().addHours(-72);
    Outreach_Event__c e = scheduledEvent(a, n, at);

    Test.startTest();
    Database.executeBatch(new OutreachEvidenceReconcileBatch(), 50);
    Test.stopTest();

    Outreach_Evidence_Link__c link = [
      SELECT Reconcile_Status__c
      FROM Outreach_Evidence_Link__c
      WHERE Outreach_Event__c = :e.Id
    ];
    System.assertEquals('Reopened', link.Reconcile_Status__c);
    System.assertEquals(
      'Pending',
      [SELECT State__c FROM Patient_Need__c WHERE Id = :n.Id].State__c
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Outreach_Event__c
        WHERE
          Patient__c = :a.Id
          AND Event_Type__c = 'Reopened'
          AND Shadow__c = TRUE
      ]
    );
  }

  @IsTest
  static void schedulerEnqueuesBatch() {
    Test.startTest();
    String jobId = OutreachEvidenceReconcileScheduler.scheduleDaily();
    // Cover execute path without waiting for cron.
    new OutreachEvidenceReconcileScheduler(10).execute(null);
    // Second call aborts/reschedules existing job.
    String jobId2 = OutreachEvidenceReconcileScheduler.scheduleDaily();
    Test.stopTest();
    System.assertNotEquals(null, jobId);
    System.assertNotEquals(null, jobId2);
  }

  @IsTest
  static void splitTypesAndFindMatchHelpers() {
    Set<String> parts = OutreachEvidenceReconcileBatch.splitTypes(
      'Annual Wellness Visit; Initial Visit'
    );
    System.assertEquals(2, parts.size());
    Outreach_Event__c e = new Outreach_Event__c(Event_At__c = System.now());
    Appointment__c a = new Appointment__c(
      Start_Date_Time__c = System.now().addHours(2),
      Type__c = 'Annual Wellness Visit'
    );
    System.assertNotEquals(
      null,
      OutreachEvidenceReconcileBatch.findMatch(
        e,
        new List<Appointment__c>{ a },
        new Set<String>{ 'Annual Wellness Visit' }
      )
    );
    System.assertEquals(
      null,
      OutreachEvidenceReconcileBatch.findMatch(
        e,
        new List<Appointment__c>{ a },
        new Set<String>{ 'Initial Visit' }
      )
    );
  }
}
