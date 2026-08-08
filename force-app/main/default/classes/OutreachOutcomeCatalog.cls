/**
 * Admin-configurable call results and channels (Outreach_Call_Result__mdt / Outreach_Channel__mdt).
 */
public with sharing class OutreachOutcomeCatalog {
  public class CallResultDTO {
    @AuraEnabled
    public String developerName { get; set; }
    @AuraEnabled
    public String label { get; set; }
    @AuraEnabled
    public String lifecycle { get; set; }
    @AuraEnabled
    public String eventType { get; set; }
    @AuraEnabled
    public Boolean showOnTimeline { get; set; }
    @AuraEnabled
    public Boolean requiresEvidence { get; set; }
    @AuraEnabled
    public String evidenceKind { get; set; }
    @AuraEnabled
    public Boolean closesCareItem { get; set; }
    @AuraEnabled
    public Boolean snoozes { get; set; }
    @AuraEnabled
    public Decimal sortOrder { get; set; }
    @AuraEnabled
    public Boolean enabled { get; set; }
  }

  public class ChannelDTO {
    @AuraEnabled
    public String developerName { get; set; }
    @AuraEnabled
    public String label { get; set; }
    @AuraEnabled
    public Decimal sortOrder { get; set; }
    @AuraEnabled
    public Boolean enabled { get; set; }
  }

  public class CatalogDTO {
    @AuraEnabled
    public List<CallResultDTO> callResults { get; set; }
    @AuraEnabled
    public List<ChannelDTO> channels { get; set; }
  }

  private static CatalogDTO cached;

  @AuraEnabled(cacheable=true)
  public static CatalogDTO getCatalog() {
    return load(false);
  }

  public static CatalogDTO load(Boolean includeDisabled) {
    CatalogDTO c = new CatalogDTO();
    c.callResults = new List<CallResultDTO>();
    c.channels = new List<ChannelDTO>();
    for (Outreach_Call_Result__mdt r : [
      SELECT
        DeveloperName,
        MasterLabel,
        Enabled__c,
        Sort_Order__c,
        Lifecycle__c,
        Event_Type__c,
        Show_On_Timeline__c,
        Requires_Evidence__c,
        Evidence_Kind__c,
        Closes_Care_Item__c,
        Snoozes__c
      FROM Outreach_Call_Result__mdt
      ORDER BY Sort_Order__c ASC NULLS LAST, MasterLabel ASC
    ]) {
      if (!includeDisabled && r.Enabled__c != true)
        continue;
      CallResultDTO d = new CallResultDTO();
      d.developerName = r.DeveloperName;
      d.label = r.MasterLabel;
      d.lifecycle = r.Lifecycle__c;
      d.eventType = r.Event_Type__c;
      d.showOnTimeline = r.Show_On_Timeline__c == true;
      d.requiresEvidence = r.Requires_Evidence__c == true;
      d.evidenceKind = r.Evidence_Kind__c;
      d.closesCareItem = r.Closes_Care_Item__c == true;
      d.snoozes = r.Snoozes__c == true;
      d.sortOrder = r.Sort_Order__c;
      d.enabled = r.Enabled__c == true;
      c.callResults.add(d);
    }
    for (Outreach_Channel__mdt r : [
      SELECT DeveloperName, MasterLabel, Enabled__c, Sort_Order__c, Label__c
      FROM Outreach_Channel__mdt
      ORDER BY Sort_Order__c ASC NULLS LAST, MasterLabel ASC
    ]) {
      if (!includeDisabled && r.Enabled__c != true)
        continue;
      ChannelDTO d = new ChannelDTO();
      d.developerName = r.DeveloperName;
      d.label = String.isBlank(r.Label__c) ? r.MasterLabel : r.Label__c;
      d.sortOrder = r.Sort_Order__c;
      d.enabled = r.Enabled__c == true;
      c.channels.add(d);
    }
    return c;
  }

  /** Map agent-facing outcome label → Event_Type__c (fallback Attempt Made). */
  public static String eventTypeForOutcome(String outcome) {
    if (String.isBlank(outcome))
      return 'Attempt Made';
    String key = outcome.trim().toLowerCase();
    for (CallResultDTO r : load(true).callResults) {
      if (r.label != null && r.label.trim().toLowerCase() == key) {
        return String.isBlank(r.eventType) ? 'Attempt Made' : r.eventType;
      }
    }
    // Legacy aliases
    if (key == 'patient scheduled')
      return 'Appointment Scheduled';
    if (key == 'suppressed' || key == 'silenced')
      return 'Suppressed';
    return 'Attempt Made';
  }

  public static CallResultDTO findByLabel(String outcome) {
    if (String.isBlank(outcome))
      return null;
    String key = outcome.trim().toLowerCase();
    for (CallResultDTO r : load(true).callResults) {
      if (r.label != null && r.label.trim().toLowerCase() == key)
        return r;
    }
    return null;
  }

  public static Boolean closesCareItem(String outcome) {
    CallResultDTO r = findByLabel(outcome);
    return r != null && r.closesCareItem == true;
  }

  public static Boolean snoozes(String outcome) {
    CallResultDTO r = findByLabel(outcome);
    return r != null && r.snoozes == true;
  }
}
