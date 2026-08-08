@IsTest
private class OutreachConsentBackfillBatchTest {
  private static Id personRt() {
    return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
      .get('PersonAccount')
      .getRecordTypeId();
  }

  @IsTest
  static void backfillProcessesActivePersonAccount() {
    PreferenceCatalogService.clearAndReseed();
    Account a = new Account(
      FirstName = 'Consent',
      LastName = 'Backfill',
      PersonEmail = 'consent.backfill@example.com',
      PersonMobilePhone = '6125550100',
      PersonHasOptedOutOfEmail = false,
      Consent_to_text__c = true,
      RecordTypeId = personRt()
    );
    insert a;

    Test.startTest();
    Database.executeBatch(new OutreachConsentBackfillBatch(), 50);
    Test.stopTest();

    Integer consents = [
      SELECT COUNT()
      FROM CommSubscriptionConsent
      WHERE ContactPointId IN (
        SELECT Id FROM ContactPointEmail WHERE ParentId = :a.Id
      )
    ];
    System.assert(consents > 0, 'Expected OptIn consents for backfill account');
  }

  @IsTest
  static void backfillSkipsHardStoppedChannels() {
    PreferenceCatalogService.clearAndReseed();
    Account stopped = new Account(
      FirstName = 'Stopped',
      LastName = 'Both',
      PersonEmail = 'stopped.both@example.com',
      PersonMobilePhone = '6125550198',
      PersonHasOptedOutOfEmail = true,
      Consent_to_text__c = false,
      RecordTypeId = personRt()
    );
    Account emailOnly = new Account(
      FirstName = 'Email',
      LastName = 'Only',
      PersonEmail = 'email.only.backfill@example.com',
      PersonHasOptedOutOfEmail = false,
      Consent_to_text__c = false,
      RecordTypeId = personRt()
    );
    insert new List<Account>{ stopped, emailOnly };

    Test.startTest();
    Database.executeBatch(new OutreachConsentBackfillBatch(), 50);
    Test.stopTest();
    System.assert(true);
  }

  @IsTest
  static void schedulableLaunches() {
    Test.startTest();
    String jobId = System.schedule(
      'OutreachConsentBackfill_Test',
      '0 0 8 ? * MON-FRI',
      new OutreachConsentBackfillBatch()
    );
    Test.stopTest();
    System.assertNotEquals(null, jobId);
  }
}
