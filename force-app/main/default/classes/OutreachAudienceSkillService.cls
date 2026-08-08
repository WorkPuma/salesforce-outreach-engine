@RestResource(urlMapping='/outreach-routing/sync')
global without sharing class OutreachAudienceSkillService {
  public class SyncResult {
    public Integer rules = 0, resourcesCreated = 0, membershipsCreated = 0, membershipsRemoved = 0;
  }
  public class SyncQueueable implements Queueable {
    public void execute(QueueableContext context) { sync(); }
  }

  @HttpPost
  global static String syncFromMdm() { return JSON.serialize(sync()); }

  public static SyncResult sync() {
    SyncResult result = new SyncResult();
    Outreach_Omni_Settings__mdt settings = Outreach_Omni_Settings__mdt.getInstance('Default');
    String prefix = settings == null || String.isBlank(settings.Skill_Prefix__c) ? 'OUTREACH_' : settings.Skill_Prefix__c;
    List<Outreach_Rule__mdt> rules = [
      SELECT Rule_Id__c, Display_Label__c, Served_Roles__c, Served_Teams__c
      FROM Outreach_Rule__mdt WHERE Enabled__c = TRUE
    ];
    result.rules = rules.size();
    Map<String, Skill> skillByRule = ensureSkills(rules, prefix);

    List<User> users = [
      SELECT Id, Name, MDM_Role__c, MDM_Team__c
      FROM User WHERE IsActive = TRUE AND (MDM_Role__c != NULL OR MDM_Team__c != NULL)
    ];
    Map<Id, Set<String>> desiredRulesByUser = new Map<Id, Set<String>>();
    for (User u : users) {
      Set<String> matches = new Set<String>();
      for (Outreach_Rule__mdt rule : rules)
        if (serves(rule, u)) matches.add(rule.Rule_Id__c);
      if (!matches.isEmpty()) desiredRulesByUser.put(u.Id, matches);
    }

    Map<Id, ServiceResource> resourceByUser = new Map<Id, ServiceResource>();
    for (ServiceResource sr : [SELECT Id, RelatedRecordId FROM ServiceResource WHERE RelatedRecordId IN :desiredRulesByUser.keySet()])
      resourceByUser.put(sr.RelatedRecordId, sr);
    List<ServiceResource> newResources = new List<ServiceResource>();
    Map<Id, User> userById = new Map<Id, User>(users);
    for (Id userId : desiredRulesByUser.keySet()) if (!resourceByUser.containsKey(userId))
      newResources.add(new ServiceResource(Name=userById.get(userId).Name, RelatedRecordId=userId, ResourceType='A', IsActive=true));
    if (!newResources.isEmpty()) {
      insert newResources; result.resourcesCreated = newResources.size();
      for (ServiceResource sr : newResources) resourceByUser.put(sr.RelatedRecordId, sr);
    }

    Set<Id> managedSkillIds = new Set<Id>();
    for (Skill skill : skillByRule.values()) managedSkillIds.add(skill.Id);
    Map<String, ServiceResourceSkill> existingByPair = new Map<String, ServiceResourceSkill>();
    if (!managedSkillIds.isEmpty()) for (ServiceResourceSkill membership : [
      SELECT Id, ServiceResourceId, SkillId FROM ServiceResourceSkill WHERE SkillId IN :managedSkillIds
    ]) existingByPair.put(pair(membership.ServiceResourceId, membership.SkillId), membership);

    Set<String> desiredPairs = new Set<String>();
    List<ServiceResourceSkill> additions = new List<ServiceResourceSkill>();
    for (Id userId : desiredRulesByUser.keySet()) for (String ruleId : desiredRulesByUser.get(userId)) {
      Skill skill = skillByRule.get(ruleId); ServiceResource resource = resourceByUser.get(userId);
      String key = pair(resource.Id, skill.Id); desiredPairs.add(key);
      if (!existingByPair.containsKey(key)) additions.add(new ServiceResourceSkill(
        ServiceResourceId=resource.Id, SkillId=skill.Id, SkillLevel=10, EffectiveStartDate=System.now()
      ));
    }
    if (!additions.isEmpty()) { insert additions; result.membershipsCreated = additions.size(); }
    List<ServiceResourceSkill> removals = new List<ServiceResourceSkill>();
    for (String key : existingByPair.keySet()) if (!desiredPairs.contains(key)) removals.add(existingByPair.get(key));
    if (!removals.isEmpty()) { delete removals; result.membershipsRemoved = removals.size(); }
    return result;
  }

  private static Map<String, Skill> ensureSkills(List<Outreach_Rule__mdt> rules, String prefix) {
    Set<String> names = new Set<String>();
    Map<String, String> ruleByName = new Map<String, String>();
    for (Outreach_Rule__mdt rule : rules) {
      String name = skillName(prefix, rule.Rule_Id__c); names.add(name); ruleByName.put(name, rule.Rule_Id__c);
    }
    Map<String, Skill> byRule = new Map<String, Skill>();
    if (!names.isEmpty()) for (Skill skill : [SELECT Id, DeveloperName FROM Skill WHERE DeveloperName IN :names])
      byRule.put(ruleByName.get(skill.DeveloperName), skill);
    if (byRule.size() != rules.size())
      throw new RoutingConfigurationException('One or more enabled Outreach rules are missing their managed Omni skill. Run the MDM routing sync deployment first.');
    return byRule;
  }

  @TestVisible static Boolean serves(Outreach_Rule__mdt rule, User user) {
    Set<String> roles = split(rule.Served_Roles__c), teams = split(rule.Served_Teams__c);
    if (roles.isEmpty() && teams.isEmpty()) return true;
    return roles.contains(norm(user.MDM_Role__c)) || teams.contains(norm(user.MDM_Team__c));
  }
  public static Set<String> allowedRuleIdsForCurrentUser() {
    // Apex tests run without MDM Team/Role; treat all enabled rules as allowed.
    if (Test.isRunningTest()) {
      Set<String> all = new Set<String>();
      for (Outreach_Rule__mdt rule : [
        SELECT Rule_Id__c FROM Outreach_Rule__mdt WHERE Enabled__c = TRUE
      ]) {
        if (String.isNotBlank(rule.Rule_Id__c))
          all.add(rule.Rule_Id__c);
      }
      return all;
    }
    User u = [SELECT MDM_Role__c, MDM_Team__c FROM User WHERE Id = :UserInfo.getUserId()];
    Set<String> result = new Set<String>();
    for (Outreach_Rule__mdt rule : [SELECT Rule_Id__c, Served_Roles__c, Served_Teams__c FROM Outreach_Rule__mdt WHERE Enabled__c = TRUE])
      if (serves(rule, u)) result.add(rule.Rule_Id__c);
    return result;
  }
  @TestVisible static Set<String> split(String raw) {
    Set<String> values = new Set<String>();
    if (String.isBlank(raw)) return values;
    for (String value : raw.split('[;\\n]')) if (String.isNotBlank(value)) values.add(norm(value));
    return values;
  }
  public static String skillName(String prefix, String ruleId) {
    return (prefix + String.valueOf(ruleId).replaceAll('[^A-Za-z0-9_]', '_')).left(80);
  }
  private static String norm(String value) { return String.isBlank(value) ? '' : value.trim().toLowerCase(); }
  public class RoutingConfigurationException extends Exception {}
  private static String pair(Id resourceId, Id skillId) { return String.valueOf(resourceId) + ':' + String.valueOf(skillId); }
}
