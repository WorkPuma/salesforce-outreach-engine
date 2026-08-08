/**
 * Config-bench preview for Care Item Email/SMS.
 * Builds a ContentDump-shaped draft and optionally enriches via Databricks
 * Haiku (Named Credential Outreach_Compose → Prefetch/Databricks compose).
 * DEV-4684
 */
public with sharing class OutreachCommPreviewService {
  @TestVisible
  private static Boolean skipCallout = true;

  public static OutreachConfigController.CommPreviewDTO preview(
    Id accountId,
    String ruleId
  ) {
    if (accountId == null) {
      throw new AuraHandledException('Account is required.');
    }
    Account acc = [
      SELECT Id, FirstName, LastName, Name, PersonEmail, SMS_Number__c,
             PersonMobilePhone, SourceSystemIdentifier
      FROM Account
      WHERE Id = :accountId
      WITH USER_MODE
      LIMIT 1
    ];
    Outreach_Rule__mdt rule;
    if (!String.isBlank(ruleId)) {
      List<Outreach_Rule__mdt> rules = [
        SELECT Rule_Id__c, Communication_Topic__c, Communication_Class__c,
               Clinical_Priority__c, Counts_As_Outreach__c, Display_Label__c,
               Recommended_Action__c, Action_Description__c,
               Auto_Send_Email__c, Auto_Send_SMS__c
        FROM Outreach_Rule__mdt
        WHERE Rule_Id__c = :ruleId
        LIMIT 1
      ];
      if (!rules.isEmpty()) {
        rule = rules[0];
      }
    }
    String topic = rule != null && !String.isBlank(rule.Communication_Topic__c)
      ? rule.Communication_Topic__c
      : 'appointment_reminders';
    Boolean clinical = rule != null && rule.Clinical_Priority__c == true;
    OutreachConsentGate.GateResult gate = OutreachConsentGate.evaluate(
      accountId,
      topic,
      clinical
    );

    String first = String.isBlank(acc.FirstName) ? 'there' : acc.FirstName;
    String prefUrl = preferenceCenterUrl(topic);
    String subject = rule != null && !String.isBlank(rule.Display_Label__c)
      ? 'Your Care Team — ' + rule.Display_Label__c
      : 'Your Care Team Recommends a Visit';
    String emailBody =
      'Dear ' +
      first +
      ',\n\nWe hope you are doing well!\n\n' +
      (rule != null && !String.isBlank(rule.Action_Description__c)
        ? rule.Action_Description__c
        : 'We noticed you may need help scheduling your next visit.') +
      '\n\nTo schedule, call (888) 290-1209 or use your patient portal.\n\n' +
      'Manage email preferences: ' +
      prefUrl +
      '\n\nThank you for trusting us with your care.\nWith care,\nYour HealthcareOrg Care Team';
    String smsBody =
      'Hi ' +
      first +
      ', your HealthcareOrg care team recommends scheduling your next visit. ' +
      'Call 888-290-1209 (Option 1) or schedule online via the patient portal. ' +
      'We will also reach out soon to help.';

    if (!skipCallout) {
      try {
        Map<String, Object> composed = callCompose(
          accountId,
          ruleId,
          topic,
          first,
          prefUrl
        );
        if (composed != null) {
          if (composed.containsKey('email_subject'))
            subject = String.valueOf(composed.get('email_subject'));
          if (composed.containsKey('email_body'))
            emailBody = String.valueOf(composed.get('email_body'));
          if (composed.containsKey('sms_body'))
            smsBody = String.valueOf(composed.get('sms_body'));
        }
      } catch (Exception e) {
        System.debug(
          LoggingLevel.WARN,
          'Compose callout failed; using skeleton: ' + e.getMessage()
        );
      }
    }

    OutreachConfigController.CommPreviewDTO dto = new OutreachConfigController.CommPreviewDTO();
    dto.accountId = acc.Id;
    dto.accountName = acc.Name;
    dto.emailAllowed = gate.emailAllowed;
    dto.smsAllowed = gate.smsAllowed;
    dto.emailReason = gate.emailReason;
    dto.smsReason = gate.smsReason;
    dto.countsAsOutreach = rule != null && rule.Counts_As_Outreach__c == true;
    dto.autoSendEmail = rule != null && rule.Auto_Send_Email__c == true;
    dto.autoSendSms = rule != null && rule.Auto_Send_SMS__c == true;
    dto.topicKey = topic;
    dto.emailSubject = subject;
    dto.emailBody = emailBody;
    dto.smsBody = smsBody;
    dto.preferenceCenterUrl = prefUrl;
    dto.composeSource = skipCallout ? 'skeleton' : 'databricks_haiku';
    return dto;
  }

  private static String preferenceCenterUrl(String topic) {
    String base = 'https://HealthcareOrg.com/preferences';
    if (String.isBlank(topic)) {
      return base;
    }
    return base + '?type=' + EncodingUtil.urlEncode(topic, 'UTF-8');
  }

  private static Map<String, Object> callCompose(
    Id accountId,
    String ruleId,
    String topic,
    String firstName,
    String prefUrl
  ) {
    HttpRequest req = new HttpRequest();
    req.setEndpoint('callout:Outreach_Compose/compose');
    req.setMethod('POST');
    req.setHeader('Content-Type', 'application/json');
    Map<String, Object> body = new Map<String, Object>{
      'account_id' => String.valueOf(accountId),
      'rule_id' => ruleId,
      'topic' => topic,
      'first_name' => firstName,
      'preference_center_url' => prefUrl,
      'preview' => true
    };
    req.setBody(JSON.serialize(body));
    req.setTimeout(60000);
    HttpResponse res = new Http().send(req);
    if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
      throw new CalloutException(
        'Compose HTTP ' + res.getStatusCode() + ': ' + res.getBody()
      );
    }
    return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
  }
}
