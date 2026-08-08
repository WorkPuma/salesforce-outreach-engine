/**
 * Daily batch: for Person Accounts missing CommSubscriptionConsent rows,
 * default OptIn to all preference topics × Email/SMS when the account is
 * NOT hard-stopped on that channel. Never flips existing OptOut.
 * DEV-4684
 */
global without sharing class OutreachConsentBackfillBatch
  implements Database.Batchable<SObject>, Schedulable, Database.Stateful {

  global Integer accountsTouched = 0;
  global Integer consentsInserted = 0;

  global void execute(SchedulableContext sc) {
    Database.executeBatch(new OutreachConsentBackfillBatch(), 50);
  }

  global Database.QueryLocator start(Database.BatchableContext bc) {
    return Database.getQueryLocator([
      SELECT Id, PersonEmail, PersonMobilePhone, SMS_Number__c,
             PersonHasOptedOutOfEmail, Consent_to_text__c,
             et4ae5__HasOptedOutOfMobile__pc, IsPersonAccount
      FROM Account
      WHERE IsPersonAccount = true
        AND IsDeleted = false
    ]);
  }

  global void execute(Database.BatchableContext bc, List<SObject> scope) {
    List<Account> accounts = (List<Account>) scope;
    if (accounts.isEmpty()) return;

    Set<Id> accountIds = new Map<Id, Account>(accounts).keySet();

    Set<Id> emailCpIds = new Set<Id>();
    for (ContactPointEmail cpe : [
      SELECT Id FROM ContactPointEmail WHERE ParentId IN :accountIds
    ]) {
      emailCpIds.add(cpe.Id);
    }
    Set<Id> phoneCpIds = new Set<Id>();
    for (ContactPointPhone cpp : [
      SELECT Id FROM ContactPointPhone WHERE ParentId IN :accountIds
    ]) {
      phoneCpIds.add(cpp.Id);
    }
    Set<Id> cpWithConsent = new Set<Id>();
    if (!emailCpIds.isEmpty()) {
      for (CommSubscriptionConsent c : [
        SELECT ContactPointId FROM CommSubscriptionConsent
        WHERE ContactPointId IN :emailCpIds
      ]) {
        cpWithConsent.add(c.ContactPointId);
      }
    }
    if (!phoneCpIds.isEmpty()) {
      for (CommSubscriptionConsent c : [
        SELECT ContactPointId FROM CommSubscriptionConsent
        WHERE ContactPointId IN :phoneCpIds
      ]) {
        cpWithConsent.add(c.ContactPointId);
      }
    }
    Set<Id> accountsWithConsent = new Set<Id>();
    if (!cpWithConsent.isEmpty()) {
      for (ContactPointEmail cpe : [
        SELECT ParentId FROM ContactPointEmail
        WHERE ParentId IN :accountIds AND Id IN :cpWithConsent
      ]) {
        accountsWithConsent.add(cpe.ParentId);
      }
      for (ContactPointPhone cpp : [
        SELECT ParentId FROM ContactPointPhone
        WHERE ParentId IN :accountIds AND Id IN :cpWithConsent
      ]) {
        accountsWithConsent.add(cpp.ParentId);
      }
    }

    List<Account> missing = new List<Account>();
    for (Account a : accounts) {
      if (!accountsWithConsent.contains(a.Id)) {
        missing.add(a);
      }
    }
    if (missing.isEmpty()) return;

    for (String key : PreferenceCatalogService.TOPIC_KEYS) {
      PreferenceCatalogService.ensureChannelType(
        key,
        PreferenceCatalogService.TOPIC_LABELS.get(key),
        'email'
      );
      PreferenceCatalogService.ensureChannelType(
        key,
        PreferenceCatalogService.TOPIC_LABELS.get(key),
        'sms'
      );
    }

    for (Account a : missing) {
      PreferenceConsentService.SaveRequest req = new PreferenceConsentService.SaveRequest();
      req.accountId = a.Id;
      req.source = PreferenceConsentService.SOURCE_BACKFILL;
      req.updates = new List<PreferenceConsentService.TopicUpdate>();
      Boolean emailOk = a.PersonHasOptedOutOfEmail != true && !String.isBlank(a.PersonEmail);
      Boolean smsOk =
        a.et4ae5__HasOptedOutOfMobile__pc != true
        && a.Consent_to_text__c != false
        && (!String.isBlank(a.SMS_Number__c) || !String.isBlank(a.PersonMobilePhone));
      if (!emailOk && !smsOk) {
        continue;
      }
      for (String key : PreferenceCatalogService.TOPIC_KEYS) {
        if (emailOk) {
          PreferenceConsentService.TopicUpdate u = new PreferenceConsentService.TopicUpdate();
          u.topicKey = key;
          u.channel = 'email';
          u.status = 'OptIn';
          req.updates.add(u);
        }
        if (smsOk) {
          PreferenceConsentService.TopicUpdate u = new PreferenceConsentService.TopicUpdate();
          u.topicKey = key;
          u.channel = 'sms';
          u.status = 'OptIn';
          req.updates.add(u);
        }
      }
      if (req.updates.isEmpty()) continue;
      try {
        PreferenceConsentService.saveFromPreferenceCenter(req);
        accountsTouched++;
        consentsInserted += req.updates.size();
      } catch (Exception e) {
        System.debug(
          LoggingLevel.WARN,
          'OutreachConsentBackfillBatch skip ' + a.Id + ': ' + e.getMessage()
        );
      }
    }
  }

  global void finish(Database.BatchableContext bc) {
    System.debug(
      LoggingLevel.INFO,
      'OutreachConsentBackfillBatch done accounts=' +
        accountsTouched +
        ' consents~=' +
        consentsInserted
    );
  }
}
