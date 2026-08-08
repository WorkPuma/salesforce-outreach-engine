public without sharing class OutreachOmniRoutingService {
  @TestVisible static Boolean enabledOverride;
  public interface RoutingGateway {
    void insertRouting(List<PendingServiceRouting> psrs, Map<Id,Id> skillByWorkItem);
  }
  public class DmlRoutingGateway implements RoutingGateway {
    public void insertRouting(List<PendingServiceRouting> psrs, Map<Id,Id> skillByWorkItem) {
      if (psrs.isEmpty()) return;
      insert psrs;
      List<SkillRequirement> requirements = new List<SkillRequirement>();
      for (PendingServiceRouting psr : psrs) {
        requirements.add(new SkillRequirement(
          RelatedRecordId=psr.Id, SkillId=skillByWorkItem.get(psr.WorkItemId), SkillLevel=1
        ));
        psr.IsReadyForRouting = true;
      }
      insert requirements;
      update psrs;
    }
  }
  @TestVisible static RoutingGateway gatewayOverride;
  public static Boolean isEnabled() {
    if (enabledOverride != null) return enabledOverride;
    Outreach_Omni_Settings__mdt settings = Outreach_Omni_Settings__mdt.getInstance('Default');
    return settings != null && settings.Enabled__c == true;
  }

  public static void routeIfEnabled(Id episodeId) {
    if (episodeId == null) return;
    routeIfEnabled(new Set<Id>{ episodeId });
  }

  public static void routeIfEnabled(Set<Id> episodeIds) {
    if (episodeIds == null || episodeIds.isEmpty() || !isEnabled()) return;
    Outreach_Omni_Settings__mdt settings = Outreach_Omni_Settings__mdt.getInstance('Default');
    List<Outreach_Episode__c> episodes = [
      SELECT Id, Primary_Rule_Id__c, Routing_Priority__c
      FROM Outreach_Episode__c
      WHERE Id IN :episodeIds AND Status__c = 'Unclaimed'
        AND Shadow__c = FALSE AND Primary_Rule_Id__c != NULL
    ];
    if (episodes.isEmpty()) return;

    Set<Id> alreadyRouted = new Set<Id>();
    for (PendingServiceRouting current : [
      SELECT WorkItemId FROM PendingServiceRouting WHERE WorkItemId IN :episodeIds
    ]) alreadyRouted.add(current.WorkItemId);

    String prefix = String.isBlank(settings.Skill_Prefix__c) ? 'OUTREACH_' : settings.Skill_Prefix__c;
    Map<String,String> ruleBySkillName = new Map<String,String>();
    for (Outreach_Episode__c episode : episodes) {
      String name = OutreachAudienceSkillService.skillName(prefix, episode.Primary_Rule_Id__c);
      ruleBySkillName.put(name, episode.Primary_Rule_Id__c);
    }
    Map<String,Id> skillByRule = new Map<String,Id>();
    for (Skill skill : [
      SELECT Id, DeveloperName FROM Skill WHERE DeveloperName IN :ruleBySkillName.keySet()
    ]) skillByRule.put(ruleBySkillName.get(skill.DeveloperName), skill.Id);

    String serviceChannelName = String.isBlank(settings.Service_Channel_Developer_Name__c)
      ? 'Outreach_Episode' : settings.Service_Channel_Developer_Name__c;
    List<ServiceChannel> channels = [
      SELECT Id FROM ServiceChannel WHERE DeveloperName = :serviceChannelName LIMIT 1
    ];
    if (channels.isEmpty()) return;
    List<PendingServiceRouting> psrs = new List<PendingServiceRouting>();
    Map<Id,Id> skillByWorkItem = new Map<Id,Id>();
    for (Outreach_Episode__c episode : episodes) {
      Id skillId = skillByRule.get(episode.Primary_Rule_Id__c);
      if (alreadyRouted.contains(episode.Id) || skillId == null) continue;
      Integer routingPriority = episode.Routing_Priority__c == null
        ? 299999999 : Integer.valueOf(episode.Routing_Priority__c);
      psrs.add(new PendingServiceRouting(
        WorkItemId=episode.Id, ServiceChannelId=channels[0].Id,
        RoutingModel='MostAvailable', RoutingType='SkillsBased', RoutingPriority=routingPriority,
        IsReadyForRouting=false, CapacityWeight=1, PushTimeout=90, IsInterruptible=true
      ));
      skillByWorkItem.put(episode.Id, skillId);
    }
    RoutingGateway gateway = gatewayOverride == null ? new DmlRoutingGateway() : gatewayOverride;
    gateway.insertRouting(psrs, skillByWorkItem);
  }

  public static void routeAllReady() {
    if (!isEnabled()) return;
    Set<Id> episodeIds = new Set<Id>();
    for (Outreach_Episode__c episode : [
      SELECT Id FROM Outreach_Episode__c
      WHERE Status__c = 'Unclaimed' AND Shadow__c = FALSE
      ORDER BY Routing_Priority__c ASC NULLS LAST, Id ASC LIMIT 100
    ]) episodeIds.add(episode.Id);
    routeIfEnabled(episodeIds);
  }
}
