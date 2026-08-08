public inherited sharing class OutreachRulesEngineFactBuilder {
  @TestVisible
  static String isoDate(Date d) {
    if (d == null)
      return null;
    String month = d.month() < 10 ? '0' + String.valueOf(d.month()) : String.valueOf(d.month());
    String day = d.day() < 10 ? '0' + String.valueOf(d.day()) : String.valueOf(d.day());
    return String.valueOf(d.year()) + '-' + month + '-' + day;
  }

  @TestVisible
  static String isoDate(Datetime dt) {
    return dt == null ? null : isoDate(dt.date());
  }


  public static Map<Id, Map<String, Object>> buildForAccounts(
    Set<Id> accountIds,
    Set<String> suppressedKeys
  ) {
    Map<Id, Map<String, Object>> out = new Map<Id, Map<String, Object>>();
    if (accountIds == null || accountIds.isEmpty())
      return out;
    Integer year = Date.today().year();
    for (Account a : [
      SELECT
        Id,
        HealthCloudGA__Active__c,
        Primary_Product_Type__c,
        Primary_Payor__c,
        AttributedPayor__c,
        Voluntary_Alignment__c,
        Future_Appointment_Number__c,
        Exceeds_Off_Cadence_15_Percent__c,
        Total_Appointment_Number__c,
        Completed_Appointment_Number__c,
        Last_AWV_Date__c,
        Next_AWV_Due_Date__c,
        AWV_Status__c,
        Risk_Tier__c,
        Days_Since_Last_Completed_Visit__c,
        Last_Completed_Visit_Date__c,
        No_Next_Paused__c,
        SourceSystemIdentifier,
        Engagement_Score__c,
        Pressure_Score__c
      FROM Account
      WHERE Id IN :accountIds
      WITH SECURITY_ENFORCED
    ]) {
      Map<String, Object> facts = new Map<String, Object>();

      facts.put('today', isoDate(Date.today()));
      facts.put('lastAwvDate', isoDate(a.Last_AWV_Date__c));
      facts.put('nextAwvDueDate', isoDate(a.Next_AWV_Due_Date__c));
      facts.put('lastCompletedVisitDate', isoDate(a.Last_Completed_Visit_Date__c));
      facts.put('patientId', a.Id);
      facts.put('activeStatus', a.HealthCloudGA__Active__c);
      facts.put('isActiveA', a.HealthCloudGA__Active__c == 'a');
      facts.put(
        'isActiveOrPending',
        a.HealthCloudGA__Active__c == 'a' || a.HealthCloudGA__Active__c == 'p'
      );
      facts.put('productType', a.Primary_Product_Type__c);
      facts.put('payor', a.Primary_Payor__c);
      facts.put(
        'isMedicareProduct',
        a.Primary_Product_Type__c == 'Medicare B-Traditional' ||
          a.Primary_Product_Type__c == 'Medicare PPO' ||
          a.Primary_Product_Type__c == 'Medicare HMO'
      );
      facts.put(
        'isTargetPayor',
        a.Primary_Payor__c == 'Payor Betacare' ||
          a.Primary_Payor__c == 'PAYOR_ALPHA-MN' ||
          a.Primary_Payor__c == 'Medicare B-MN'
      );
      facts.put(
        'hasAttributionBlock',
        a.AttributedPayor__c != null && a.Voluntary_Alignment__c == false
      );
      facts.put(
        'futureApptCount',
        a.Future_Appointment_Number__c == null ? 0 : a.Future_Appointment_Number__c
      );
      facts.put(
        'totalApptCount',
        a.Total_Appointment_Number__c == null ? 0 : a.Total_Appointment_Number__c
      );
      facts.put(
        'completedApptCount',
        a.Completed_Appointment_Number__c == null
          ? 0
          : a.Completed_Appointment_Number__c
      );
      facts.put('exceedsOffCadence', a.Exceeds_Off_Cadence_15_Percent__c == true);
      facts.put('noNextPaused', a.No_Next_Paused__c == true);
      facts.put('hasSourceSystemId', String.isNotBlank(a.SourceSystemIdentifier));
      facts.put(
        'riskTier',
        String.isBlank(a.Risk_Tier__c) ? 'Low Risk' : a.Risk_Tier__c
      );
      facts.put(
        'daysSinceLastVisit',
        a.Days_Since_Last_Completed_Visit__c == null
          ? 0
          : a.Days_Since_Last_Completed_Visit__c
      );
      facts.put('awvStatus', a.AWV_Status__c);
      Boolean awvDue =
        a.Last_AWV_Date__c == null ||
        (a.Next_AWV_Due_Date__c != null &&
        a.Next_AWV_Due_Date__c <= Date.today().addDays(60));
      Boolean awvOpen =
        a.AWV_Status__c != ('Completed ' + year) &&
        a.AWV_Status__c != ('Scheduled ' + year);
      facts.put('awvDueWithin60', awvDue);
      facts.put('awvNotDoneOrScheduledThisYear', awvOpen);
      facts.put(
        'suppressedAWV',
        suppressedKeys != null && suppressedKeys.contains(a.Id + ':AWV')
      );
      facts.put(
        'suppressedOffCadence',
        suppressedKeys != null &&
          suppressedKeys.contains(a.Id + ':OFF_CADENCE')
      );
      facts.put(
        'suppressedNoNext',
        suppressedKeys != null && suppressedKeys.contains(a.Id + ':NO_NEXT')
      );
      facts.put(
        'engagementScore',
        a.Engagement_Score__c == null ? 0 : a.Engagement_Score__c
      );
      facts.put(
        'pressureScore',
        a.Pressure_Score__c == null ? 0 : a.Pressure_Score__c
      );
      facts.put(
        'pressureBlocked',
        OutreachQueuePolicy.isPressureBlocked(a.Pressure_Score__c)
      );
      out.put(a.Id, facts);
    }
    return out;
  }
}
