@IsTest
private class OutreachConsentGateTest {

  @IsTest
  static void hardStopBlocksEmail() {
    PreferenceCatalogService.clearAndReseed();
    Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
      .get('PersonAccount')
      .getRecordTypeId();
    Account a = new Account(
      FirstName = 'Gate',
      LastName = 'EmailStop',
      PersonEmail = 'gate.email@example.com',
      PersonHasOptedOutOfEmail = true,
      RecordTypeId = rt
    );
    insert a;
    OutreachConsentGate.GateResult g = OutreachConsentGate.evaluate(
      a.Id,
      'appointment_reminders',
      false
    );
    System.assertEquals(false, g.emailAllowed);
    System.assertEquals(true, g.emailHardStop);
  }

  @IsTest
  static void clinicalPriorityOverridesTopicOptOut() {
    PreferenceCatalogService.clearAndReseed();
    Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
      .get('PersonAccount')
      .getRecordTypeId();
    Account a = new Account(
      FirstName = 'Gate',
      LastName = 'Clinical',
      PersonEmail = 'gate.clinical@example.com',
      PersonMobilePhone = '6125550199',
      PersonHasOptedOutOfEmail = false,
      Consent_to_text__c = true,
      RecordTypeId = rt
    );
    insert a;
    PreferenceConsentService.SaveRequest req = new PreferenceConsentService.SaveRequest();
    req.accountId = a.Id;
    PreferenceConsentService.TopicUpdate u = new PreferenceConsentService.TopicUpdate();
    u.topicKey = 'appointment_reminders';
    u.channel = 'email';
    u.status = 'OptOut';
    req.updates = new List<PreferenceConsentService.TopicUpdate>{ u };
    PreferenceConsentService.saveFromPreferenceCenter(req);

    OutreachConsentGate.GateResult blocked = OutreachConsentGate.evaluate(
      a.Id,
      'appointment_reminders',
      false
    );
    System.assertEquals(false, blocked.emailAllowed);

    OutreachConsentGate.GateResult allowed = OutreachConsentGate.evaluate(
      a.Id,
      'appointment_reminders',
      true
    );
    System.assertEquals(true, allowed.emailAllowed);
  }

  @IsTest
  static void optOutTopicForSilenceWritesConsents() {
    PreferenceCatalogService.clearAndReseed();
    Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
      .get('PersonAccount')
      .getRecordTypeId();
    Account a = new Account(
      FirstName = 'Silence',
      LastName = 'OptOut',
      PersonEmail = 'silence.optout@example.com',
      PersonMobilePhone = '6125550122',
      PersonHasOptedOutOfEmail = false,
      Consent_to_text__c = true,
      RecordTypeId = rt
    );
    insert a;
    Test.startTest();
    OutreachConsentGate.optOutTopicForSilence(a.Id, 'appointment_reminders');
    Test.stopTest();
    OutreachConsentGate.GateResult g = OutreachConsentGate.evaluate(
      a.Id,
      'appointment_reminders',
      false
    );
    System.assertEquals(false, g.emailAllowed);
  }
}
