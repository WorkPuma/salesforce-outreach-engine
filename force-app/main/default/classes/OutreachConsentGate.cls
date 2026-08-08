/**
 * Consent evaluation for Outreach Care Item Email/SMS.
 * Topic OptOut may be overridden only when Clinical_Priority__c is true on the rule.
 * Hard stops never override: PersonHasOptedOutOfEmail, et4ae5 mobile opt-out,
 * Consent_to_text false, AI_Outreach_Optout__c, DoNotCall.
 */
public with sharing class OutreachConsentGate {
  public class GateResult {
    @AuraEnabled public Boolean emailAllowed;
    @AuraEnabled public Boolean smsAllowed;
    @AuraEnabled public Boolean ai_outreachOptedOut;
    @AuraEnabled public Boolean emailHardStop;
    @AuraEnabled public Boolean smsHardStop;
    @AuraEnabled public String emailReason;
    @AuraEnabled public String smsReason;
    @AuraEnabled public String topicKey;
    @AuraEnabled public Boolean clinicalPriority;
  }

  public static GateResult evaluate(Id accountId, String topicKey, Boolean clinicalPriority) {
    GateResult g = new GateResult();
    g.topicKey = topicKey;
    g.clinicalPriority = clinicalPriority == true;
    g.emailAllowed = false;
    g.smsAllowed = false;
    if (accountId == null) {
      g.emailReason = 'Missing account';
      g.smsReason = 'Missing account';
      return g;
    }
    Account acc = [
      SELECT Id, PersonHasOptedOutOfEmail, Consent_to_text__c,
             et4ae5__HasOptedOutOfMobile__pc, AI_Outreach_Optout__c, PersonDoNotCall,
             PersonEmail, SMS_Number__c, PersonMobilePhone, IsPersonAccount
      FROM Account
      WHERE Id = :accountId
      WITH USER_MODE
      LIMIT 1
    ];
    g.ai_outreachOptedOut = acc.AI_Outreach_Optout__c == true;
    g.emailHardStop = acc.PersonHasOptedOutOfEmail == true;
    Boolean smsConsentFalse = acc.Consent_to_text__c == false;
    g.smsHardStop =
      acc.et4ae5__HasOptedOutOfMobile__pc == true
      || smsConsentFalse
      || acc.PersonDoNotCall == true;

    if (g.emailHardStop) {
      g.emailReason = 'Account email hard stop (opted out)';
    }
    if (g.smsHardStop) {
      g.smsReason = 'Account SMS hard stop (opt-out / no consent / DNC)';
    }

    Map<String, String> topicStatus = loadTopicStatuses(acc.Id, topicKey);
    String emailStatus = topicStatus.get('Email');
    String smsStatus = topicStatus.get('SMS');

    if (!g.emailHardStop) {
      if (emailStatus == 'OptOut' && !g.clinicalPriority) {
        g.emailReason = 'Topic OptOut for Email';
      } else if (String.isBlank(acc.PersonEmail)) {
        g.emailReason = 'No PersonEmail';
      } else {
        g.emailAllowed = true;
        g.emailReason = (emailStatus == 'OptOut' && g.clinicalPriority)
          ? 'Clinical Priority overrides topic OptOut'
          : 'Allowed';
      }
    }

    if (!g.smsHardStop) {
      String phone = !String.isBlank(acc.SMS_Number__c) ? acc.SMS_Number__c : acc.PersonMobilePhone;
      if (smsStatus == 'OptOut' && !g.clinicalPriority) {
        g.smsReason = 'Topic OptOut for SMS';
      } else if (String.isBlank(phone)) {
        g.smsReason = 'No SMS phone';
      } else {
        g.smsAllowed = true;
        g.smsReason = (smsStatus == 'OptOut' && g.clinicalPriority)
          ? 'Clinical Priority overrides topic OptOut'
          : 'Allowed';
      }
    }
    return g;
  }

  /** OptOut topic Email+SMS consents for a silenced care item's communication topic. */
  public static void optOutTopicForSilence(Id accountId, String topicKey) {
    if (accountId == null || String.isBlank(topicKey)) {
      return;
    }
    PreferenceConsentService.SaveRequest req = new PreferenceConsentService.SaveRequest();
    req.accountId = accountId;
    req.source = PreferenceConsentService.SOURCE_PREF_CENTER;
    req.updates = new List<PreferenceConsentService.TopicUpdate>();
    for (String channel : new List<String>{ 'email', 'sms' }) {
      PreferenceConsentService.TopicUpdate u = new PreferenceConsentService.TopicUpdate();
      u.topicKey = topicKey;
      u.channel = channel;
      u.status = 'OptOut';
      req.updates.add(u);
    }
    PreferenceConsentService.saveFromPreferenceCenter(req);
  }

  private static Map<String, String> loadTopicStatuses(Id accountId, String topicKey) {
    Map<String, String> out = new Map<String, String>();
    if (String.isBlank(topicKey)) {
      out.put('Email', 'OptIn');
      out.put('SMS', 'OptIn');
      return out;
    }
    String label = PreferenceCatalogService.TOPIC_LABELS.containsKey(topicKey)
      ? PreferenceCatalogService.TOPIC_LABELS.get(topicKey)
      : topicKey;
    String nameLike = label + '%';

    Set<Id> cpIds = new Set<Id>();
    for (ContactPointEmail cpe : [
      SELECT Id FROM ContactPointEmail WHERE ParentId = :accountId
    ]) {
      cpIds.add(cpe.Id);
    }
    for (ContactPointPhone cpp : [
      SELECT Id FROM ContactPointPhone WHERE ParentId = :accountId
    ]) {
      cpIds.add(cpp.Id);
    }
    if (cpIds.isEmpty()) {
      out.put('Email', 'OptIn');
      out.put('SMS', 'OptIn');
      return out;
    }

    for (CommSubscriptionConsent row : [
      SELECT PrivacyConsentStatus, CommSubscriptionChannelType.Name,
             CommSubscriptionChannelType.EngagementChannelType.Name
      FROM CommSubscriptionConsent
      WHERE ContactPointId IN :cpIds
        AND (
          CommSubscriptionChannelType.CommunicationSubscription.Name = :label
          OR CommSubscriptionChannelType.Name LIKE :nameLike
        )
    ]) {
      String eng = row.CommSubscriptionChannelType != null
        && row.CommSubscriptionChannelType.EngagementChannelType != null
        ? row.CommSubscriptionChannelType.EngagementChannelType.Name
        : null;
      if (eng != null && !out.containsKey(eng)) {
        out.put(eng, row.PrivacyConsentStatus);
      }
    }
    if (!out.containsKey('Email')) out.put('Email', 'OptIn');
    if (!out.containsKey('SMS')) out.put('SMS', 'OptIn');
    return out;
  }
}
