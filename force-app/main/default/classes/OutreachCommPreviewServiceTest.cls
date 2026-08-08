@IsTest
private class OutreachCommPreviewServiceTest {
  private class ComposeMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      res.setBody(
        '{"email_subject":"Haiku Subject","email_body":"Dear Jane,\\nManage email preferences: https://HealthcareOrg.com/preferences?type=appointment_reminders","sms_body":"Hi Jane, schedule soon."}'
      );
      return res;
    }
  }

  private static Id personRt() {
    return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
      .get('PersonAccount')
      .getRecordTypeId();
  }

  @IsTest
  static void previewReturnsSkeletonWithPreferenceLink() {
    PreferenceCatalogService.clearAndReseed();
    Account a = new Account(
      FirstName = 'Preview',
      LastName = 'Patient',
      PersonEmail = 'preview.patient@example.com',
      PersonMobilePhone = '6125550111',
      PersonHasOptedOutOfEmail = false,
      Consent_to_text__c = true,
      RecordTypeId = personRt()
    );
    insert a;
    OutreachConfigController.skipWriteCheck = true;
    OutreachCommPreviewService.skipCallout = true;
    Test.startTest();
    OutreachConfigController.CommPreviewDTO dto = OutreachCommPreviewService.preview(
      a.Id,
      'AWV_DUE'
    );
    OutreachConfigController.CommPreviewDTO viaCtrl = OutreachConfigController.previewCareItemComm(
      a.Id,
      'OFF_CADENCE'
    );
    Test.stopTest();
    System.assertNotEquals(null, dto.emailBody);
    System.assert(dto.emailBody.containsIgnoreCase('preferences'), dto.emailBody);
    System.assert(!dto.smsBody.toLowerCase().contains('stop'));
    System.assertEquals('skeleton', dto.composeSource);
    System.assertNotEquals(null, dto.autoSendEmail);
    System.assertNotEquals(null, dto.autoSendSms);
    System.assertNotEquals(null, viaCtrl.emailSubject);
    System.assertNotEquals(null, viaCtrl.autoSendEmail);
    System.assertNotEquals(null, viaCtrl.autoSendSms);
  }

  @IsTest
  static void previewUsesCalloutWhenEnabled() {
    PreferenceCatalogService.clearAndReseed();
    Account a = new Account(
      FirstName = 'Callout',
      LastName = 'Patient',
      PersonEmail = 'callout.patient@example.com',
      PersonMobilePhone = '6125550133',
      PersonHasOptedOutOfEmail = false,
      Consent_to_text__c = true,
      RecordTypeId = personRt()
    );
    insert a;
    OutreachCommPreviewService.skipCallout = false;
    Test.setMock(HttpCalloutMock.class, new ComposeMock());
    Test.startTest();
    OutreachConfigController.CommPreviewDTO dto = OutreachCommPreviewService.preview(
      a.Id,
      'AWV_DUE'
    );
    Test.stopTest();
    System.assertEquals('Haiku Subject', dto.emailSubject);
    System.assertEquals('databricks_haiku', dto.composeSource);
  }

  @IsTest
  static void searchAccountsByName() {
    Account a = new Account(
      FirstName = 'Searchy',
      LastName = 'UniquePreviewName',
      PersonEmail = 'searchy@example.com',
      RecordTypeId = personRt()
    );
    insert a;
    OutreachConfigController.skipWriteCheck = true;
    Test.startTest();
    List<OutreachConfigController.AccountSearchDTO> rows = OutreachConfigController.searchAccountsForPreview(
      'UniquePreviewName'
    );
    List<OutreachConfigController.AccountSearchDTO> empty = OutreachConfigController.searchAccountsForPreview(
      'x'
    );
    Test.stopTest();
    System.assert(!rows.isEmpty());
    System.assertEquals(0, empty.size());
  }

  @IsTest
  static void previewHardStopEmail() {
    Account a = new Account(
      FirstName = 'Hard',
      LastName = 'Stop',
      PersonEmail = 'hard.stop@example.com',
      PersonHasOptedOutOfEmail = true,
      RecordTypeId = personRt()
    );
    insert a;
    OutreachCommPreviewService.skipCallout = true;
    Test.startTest();
    OutreachConfigController.CommPreviewDTO dto = OutreachCommPreviewService.preview(
      a.Id,
      null
    );
    Test.stopTest();
    System.assertEquals(false, dto.emailAllowed);
  }

  @IsTest
  static void silenceQueueableRuns() {
    PreferenceCatalogService.clearAndReseed();
    Account a = new Account(
      FirstName = 'Q',
      LastName = 'Silence',
      PersonEmail = 'q.silence@example.com',
      PersonMobilePhone = '6125550144',
      PersonHasOptedOutOfEmail = false,
      Consent_to_text__c = true,
      RecordTypeId = personRt()
    );
    insert a;
    Test.startTest();
    System.enqueueJob(
      new OutreachSilenceConsentQueueable(a.Id, 'appointment_reminders')
    );
    Test.stopTest();
    OutreachConsentGate.GateResult g = OutreachConsentGate.evaluate(
      a.Id,
      'appointment_reminders',
      false
    );
    System.assertEquals(false, g.emailAllowed);
  }
}
