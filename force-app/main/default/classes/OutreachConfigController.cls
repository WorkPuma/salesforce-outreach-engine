/**
 * Permission-gated CRUD for Outreach custom metadata.
 * Writes enqueue Metadata.DeployContainer jobs (async); reads via SOQL.
 */
public with sharing class OutreachConfigController {
  private static final String PERM = 'Outreach_Configuration_Admin';

  @TestVisible
  private static Boolean forceDenyWrite = false;
  @TestVisible
  private static Boolean skipWriteCheck = false;

  public class AccessDeniedException extends Exception {
  }
  public class ConfigException extends Exception {
  }

  public class AccessDTO {
    @AuraEnabled
    public Boolean canManage { get; set; }
    @AuraEnabled
    public String username { get; set; }
  }

  public class EngineSettingsDTO {
    @AuraEnabled
    public String developerName { get; set; }
    @AuraEnabled
    public String masterLabel { get; set; }
    @AuraEnabled
    public String defaultCadenceTemplate { get; set; }
    @AuraEnabled
    public Decimal defaultAttemptIntervalDays { get; set; }
    @AuraEnabled
    public Decimal defaultMaxAttempts { get; set; }
    @AuraEnabled
    public Decimal defaultPauseDurationDays { get; set; }
    @AuraEnabled
    public Decimal defaultReopenWindowHours { get; set; }
    @AuraEnabled
    public Decimal defaultCloseCooldownHours { get; set; }
    @AuraEnabled
    public Boolean pressureBlockEnabled { get; set; }
    @AuraEnabled
    public Decimal pressureBlockThreshold { get; set; }
    @AuraEnabled
    public String rankingStrategy { get; set; }
    @AuraEnabled
    public Decimal engagementWeight { get; set; }
    @AuraEnabled
    public Decimal engagementRangeMin { get; set; }
    @AuraEnabled
    public Decimal engagementRangeMax { get; set; }
    @AuraEnabled
    public Decimal randomSaltHours { get; set; }
  }

  public class RuleDTO {
    @AuraEnabled
    public String developerName { get; set; }
    @AuraEnabled
    public String masterLabel { get; set; }
    @AuraEnabled
    public String ruleId { get; set; }
    @AuraEnabled
    public String version { get; set; }
    @AuraEnabled
    public String displayLabel { get; set; }
    @AuraEnabled
    public String description { get; set; }
    @AuraEnabled
    public String family { get; set; }
    @AuraEnabled
    public String needType { get; set; }
    @AuraEnabled
    public String category { get; set; }
    @AuraEnabled
    public Boolean enabled { get; set; }
    @AuraEnabled
    public Boolean shadowOnly { get; set; }
    @AuraEnabled
    public Boolean bypassPressureGate { get; set; }
    @AuraEnabled
    public Boolean overrideWeeklyQueueCooldown { get; set; }
    @AuraEnabled
    public Boolean overrideDailyAttemptLimit { get; set; }
    @AuraEnabled
    public Boolean forceAcknowledge { get; set; }
    @AuraEnabled
    public Boolean useGlobalCadence { get; set; }
    @AuraEnabled
    public String cadencePolicy { get; set; }
    @AuraEnabled
    public String servedRoles { get; set; }
    @AuraEnabled
    public String servedTeams { get; set; }
    @AuraEnabled
    public String requiredAppointmentTypes { get; set; }
    @AuraEnabled
    public String supersedesFamilies { get; set; }
    @AuraEnabled
    public String recommendedAction { get; set; }
    @AuraEnabled
    public String actionDescription { get; set; }
    @AuraEnabled
    public Decimal sortOrder { get; set; }
    @AuraEnabled
    public Date effectiveStart { get; set; }
    @AuraEnabled
    public Date effectiveEnd { get; set; }
    @AuraEnabled
    public String communicationTopic { get; set; }
    @AuraEnabled
    public String communicationClass { get; set; }
    @AuraEnabled
    public Boolean clinicalPriority { get; set; }
    @AuraEnabled
    public Boolean countsAsOutreach { get; set; }
    @AuraEnabled
    public Boolean autoSendEmail { get; set; }
    @AuraEnabled
    public Boolean autoSendSms { get; set; }
  }

  public class CadenceDTO {
    @AuraEnabled
    public String developerName { get; set; }
    @AuraEnabled
    public String masterLabel { get; set; }
    @AuraEnabled
    public String description { get; set; }
    @AuraEnabled
    public Decimal maxAttempts { get; set; }
    @AuraEnabled
    public Decimal attemptIntervalDays { get; set; }
    @AuraEnabled
    public Decimal pauseDurationDays { get; set; }
    @AuraEnabled
    public Decimal reopenWindowHours { get; set; }
    @AuraEnabled
    public Decimal closeCooldownHours { get; set; }
    @AuraEnabled
    public Boolean overrideSnooze { get; set; }
    @AuraEnabled
    public Boolean resetOnPromotion { get; set; }
  }

  public class RulesEngineDTO {
    @AuraEnabled
    public String developerName { get; set; }
    @AuraEnabled
    public String masterLabel { get; set; }
    @AuraEnabled
    public Boolean enabled { get; set; }
    @AuraEnabled
    public String projectSlug { get; set; }
    @AuraEnabled
    public String surfaceDecisionKey { get; set; }
    @AuraEnabled
    public String reactionDecisionKey { get; set; }
    @AuraEnabled
    public String namedCredential { get; set; }
    @AuraEnabled
    public Decimal batchSize { get; set; }
  }

  public class OmniDTO {
    @AuraEnabled
    public String developerName { get; set; }
    @AuraEnabled
    public String masterLabel { get; set; }
    @AuraEnabled
    public Boolean enabled { get; set; }
    @AuraEnabled
    public String skillPrefix { get; set; }
    @AuraEnabled
    public String serviceChannelDeveloperName { get; set; }
    @AuraEnabled
    public String routingConfigDeveloperName { get; set; }
  }

  public class BundleDTO {
    @AuraEnabled
    public AccessDTO access { get; set; }
    @AuraEnabled
    public EngineSettingsDTO engine { get; set; }
    @AuraEnabled
    public List<RuleDTO> rules { get; set; }
    @AuraEnabled
    public List<CadenceDTO> cadencePolicies { get; set; }
    @AuraEnabled
    public RulesEngineDTO rulesEngine { get; set; }
    @AuraEnabled
    public OmniDTO omni { get; set; }
    @AuraEnabled
    public List<String> rankingStrategies { get; set; }
    @AuraEnabled
    public List<String> cadenceOptions { get; set; }
    @AuraEnabled
    public List<String> availableTeams { get; set; }
    @AuraEnabled
    public List<String> availableRoles { get; set; }
    @AuraEnabled
    public List<String> availableAppointmentTypes { get; set; }
    @AuraEnabled
    public OutreachOutcomeCatalog.CatalogDTO outcomeCatalog { get; set; }
  }

  public class SaveResultDTO {
    @AuraEnabled
    public Id deployJobId { get; set; }
    @AuraEnabled
    public String message { get; set; }
  }

  @AuraEnabled(cacheable=true)
  public static AccessDTO getAccess() {
    AccessDTO a = new AccessDTO();
    a.canManage = FeatureManagement.checkPermission(PERM);
    a.username = UserInfo.getUserName();
    return a;
  }

  @AuraEnabled
  public static BundleDTO getBundle() {
    requireRead();
    BundleDTO b = new BundleDTO();
    b.access = getAccess();
    b.engine = loadEngine();
    b.rules = loadRules();
    b.cadencePolicies = loadCadence();
    b.rulesEngine = loadRulesEngine();
    b.omni = loadOmni();
    b.rankingStrategies = new List<String>{
      'NEUTRAL',
      'HIGH',
      'LOW',
      'RANGE',
      'RANDOM'
    };
    b.cadenceOptions = new List<String>();
    for (CadenceDTO c : b.cadencePolicies)
      b.cadenceOptions.add(c.developerName);
    b.availableTeams = loadAvailableTeams(b.rules);
    b.availableRoles = loadAvailableRoles(b.rules);
    b.availableAppointmentTypes = loadAppointmentTypes();
    b.outcomeCatalog = OutreachOutcomeCatalog.load(true);
    return b;
  }

  @AuraEnabled
  public static SaveResultDTO saveEngine(EngineSettingsDTO dto) {
    requireWrite();
    if (dto == null)
      throw new ConfigException('Engine settings record is required.');
    if (String.isBlank(dto.developerName))
      dto.developerName = 'Default';
    Metadata.CustomMetadata cmd = baseCmd(
      'Outreach_Engine_Settings__mdt.' + dto.developerName,
      String.isBlank(dto.masterLabel) ? dto.developerName : dto.masterLabel
    );
    put(cmd, 'Default_Cadence_Template__c', dto.defaultCadenceTemplate);
    put(cmd, 'Default_Attempt_Interval_Days__c', dto.defaultAttemptIntervalDays);
    put(cmd, 'Default_Max_Attempts__c', dto.defaultMaxAttempts);
    put(cmd, 'Default_Pause_Duration_Days__c', dto.defaultPauseDurationDays);
    put(cmd, 'Default_Reopen_Window_Hours__c', dto.defaultReopenWindowHours);
    put(cmd, 'Default_Close_Cooldown_Hours__c', dto.defaultCloseCooldownHours);
    put(cmd, 'Pressure_Block_Enabled__c', dto.pressureBlockEnabled == true);
    put(cmd, 'Pressure_Block_Threshold__c', dto.pressureBlockThreshold);
    put(cmd, 'Ranking_Strategy__c', dto.rankingStrategy);
    put(cmd, 'Engagement_Weight__c', dto.engagementWeight);
    put(cmd, 'Engagement_Range_Min__c', dto.engagementRangeMin);
    put(cmd, 'Engagement_Range_Max__c', dto.engagementRangeMax);
    put(cmd, 'Random_Salt_Hours__c', dto.randomSaltHours);
    return enqueue(cmd, 'Queue & ranking settings queued to deploy.');
  }

  @AuraEnabled
  public static SaveResultDTO saveRule(RuleDTO dto) {
    requireWrite();
    if (dto == null || String.isBlank(dto.developerName))
      throw new ConfigException('Rule developer name is required.');
    if (String.isBlank(dto.ruleId))
      throw new ConfigException('Rule Id is required.');
    Metadata.CustomMetadata cmd = baseCmd(
      'Outreach_Rule__mdt.' + dto.developerName,
      String.isBlank(dto.masterLabel)
        ? (String.isBlank(dto.displayLabel) ? dto.developerName : dto.displayLabel)
        : dto.masterLabel
    );
    put(cmd, 'Rule_Id__c', dto.ruleId);
    put(cmd, 'Version__c', dto.version);
    put(cmd, 'Display_Label__c', dto.displayLabel);
    put(cmd, 'Description__c', dto.description);
    put(cmd, 'Family__c', dto.family);
    put(cmd, 'Need_Type__c', dto.needType);
    put(cmd, 'Category__c', dto.category);
    put(cmd, 'Enabled__c', dto.enabled == true);
    put(cmd, 'Shadow_Only__c', dto.shadowOnly == true);
    put(cmd, 'Bypass_Pressure_Gate__c', dto.bypassPressureGate == true);
    put(cmd, 'Override_Weekly_Queue_Cooldown__c', dto.overrideWeeklyQueueCooldown == true);
    put(cmd, 'Override_Daily_Attempt_Limit__c', dto.overrideDailyAttemptLimit == true);
    put(cmd, 'Force_Acknowledge__c', dto.forceAcknowledge == true);
    put(cmd, 'Use_Global_Cadence__c', dto.useGlobalCadence == true);
    put(cmd, 'Cadence_Policy__c', dto.cadencePolicy);
    put(cmd, 'Served_Roles__c', normalizeServedList(dto.servedRoles));
    put(cmd, 'Served_Teams__c', normalizeServedList(dto.servedTeams));
    put(cmd, 'Required_Appointment_Types__c', normalizeServedList(dto.requiredAppointmentTypes));
    put(cmd, 'Supersedes_Families__c', dto.supersedesFamilies);
    put(cmd, 'Recommended_Action__c', dto.recommendedAction);
    put(cmd, 'Action_Description__c', dto.actionDescription);
    put(cmd, 'Sort_Order__c', dto.sortOrder);
    put(cmd, 'Effective_Start__c', dto.effectiveStart);
    put(cmd, 'Effective_End__c', dto.effectiveEnd);
    put(cmd, 'Communication_Topic__c', dto.communicationTopic);
    put(cmd, 'Communication_Class__c', dto.communicationClass);
    put(cmd, 'Clinical_Priority__c', dto.clinicalPriority == true);
    put(cmd, 'Counts_As_Outreach__c', dto.countsAsOutreach == true);
    put(cmd, 'Auto_Send_Email__c', dto.autoSendEmail == true);
    put(cmd, 'Auto_Send_SMS__c', dto.autoSendSms == true);
    return enqueue(cmd, 'Rule “' + dto.ruleId + '” queued to deploy.');
  }

  @AuraEnabled
  public static SaveResultDTO saveCadence(CadenceDTO dto) {
    requireWrite();
    if (dto == null || String.isBlank(dto.developerName))
      throw new ConfigException('Cadence developer name is required.');
    Metadata.CustomMetadata cmd = baseCmd(
      'Cadence_Policy__mdt.' + dto.developerName,
      String.isBlank(dto.masterLabel) ? dto.developerName : dto.masterLabel
    );
    put(cmd, 'Description__c', dto.description);
    put(cmd, 'Max_Attempts__c', dto.maxAttempts);
    put(cmd, 'Attempt_Interval_Days__c', dto.attemptIntervalDays);
    put(cmd, 'Pause_Duration_Days__c', dto.pauseDurationDays);
    put(cmd, 'Reopen_Window_Hours__c', dto.reopenWindowHours);
    put(cmd, 'Close_Cooldown_Hours__c', dto.closeCooldownHours);
    put(cmd, 'Override_Snooze__c', dto.overrideSnooze == true);
    put(cmd, 'Reset_On_Promotion__c', dto.resetOnPromotion == true);
    return enqueue(cmd, 'Cadence policy queued to deploy.');
  }

  @AuraEnabled
  public static SaveResultDTO saveRulesEngine(RulesEngineDTO dto) {
    requireWrite();
    if (dto == null || String.isBlank(dto.developerName))
      throw new ConfigException('RulesEngine settings record is required.');
    Metadata.CustomMetadata cmd = baseCmd(
      'Outreach_RulesEngine_Settings__mdt.' + dto.developerName,
      String.isBlank(dto.masterLabel) ? dto.developerName : dto.masterLabel
    );
    put(cmd, 'Enabled__c', dto.enabled == true);
    put(cmd, 'Project_Slug__c', dto.projectSlug);
    put(cmd, 'Surface_Decision_Key__c', dto.surfaceDecisionKey);
    put(cmd, 'Reaction_Decision_Key__c', dto.reactionDecisionKey);
    put(cmd, 'Named_Credential__c', dto.namedCredential);
    put(cmd, 'Batch_Size__c', dto.batchSize);
    return enqueue(cmd, 'RulesEngine settings queued to deploy.');
  }

  @AuraEnabled
  public static SaveResultDTO saveOmni(OmniDTO dto) {
    requireWrite();
    if (dto == null || String.isBlank(dto.developerName))
      throw new ConfigException('Omni settings record is required.');
    Metadata.CustomMetadata cmd = baseCmd(
      'Outreach_Omni_Settings__mdt.' + dto.developerName,
      String.isBlank(dto.masterLabel) ? dto.developerName : dto.masterLabel
    );
    put(cmd, 'Enabled__c', dto.enabled == true);
    put(cmd, 'Skill_Prefix__c', dto.skillPrefix);
    put(cmd, 'Service_Channel_Developer_Name__c', dto.serviceChannelDeveloperName);
    put(cmd, 'Routing_Config_Developer_Name__c', dto.routingConfigDeveloperName);
    return enqueue(cmd, 'Omni routing settings queued to deploy.');
  }

  private static void requireRead() {
    // Any authenticated user with Apex access can read; write is gated.
    // Tab itself is permission-set gated.
  }

  private static void requireConfigAccess() {
    if (skipWriteCheck) {
      return;
    }
    if (forceDenyWrite || !FeatureManagement.checkPermission(PERM)) {
      throw new AccessDeniedException(
        'You need the Outreach Configuration Admin permission set to preview communications.'
      );
    }
  }

  private static void requireWrite() {
    if (forceDenyWrite)
      throw new AccessDeniedException(
        'You need the Outreach Configuration Admin permission set to change outreach settings.'
      );
    if (skipWriteCheck)
      return;
    if (!FeatureManagement.checkPermission(PERM))
      throw new AccessDeniedException(
        'You need the Outreach Configuration Admin permission set to change outreach settings.'
      );
  }

  private static EngineSettingsDTO loadEngine() {
    List<Outreach_Engine_Settings__mdt> rows = [
      SELECT
        DeveloperName,
        MasterLabel,
        Default_Cadence_Template__c,
        Default_Attempt_Interval_Days__c,
        Default_Max_Attempts__c,
        Default_Pause_Duration_Days__c,
        Default_Reopen_Window_Hours__c,
        Default_Close_Cooldown_Hours__c,
        Pressure_Block_Enabled__c,
        Pressure_Block_Threshold__c,
        Ranking_Strategy__c,
        Engagement_Weight__c,
        Engagement_Range_Min__c,
        Engagement_Range_Max__c,
        Random_Salt_Hours__c
      FROM Outreach_Engine_Settings__mdt
      WHERE DeveloperName = 'Default'
      LIMIT 1
    ];
    if (rows.isEmpty())
      return null;
    Outreach_Engine_Settings__mdt r = rows[0];
    EngineSettingsDTO d = new EngineSettingsDTO();
    d.developerName = r.DeveloperName;
    d.masterLabel = r.MasterLabel;
    d.defaultCadenceTemplate = r.Default_Cadence_Template__c;
    d.defaultAttemptIntervalDays = r.Default_Attempt_Interval_Days__c;
    d.defaultMaxAttempts = r.Default_Max_Attempts__c;
    d.defaultPauseDurationDays = r.Default_Pause_Duration_Days__c;
    d.defaultReopenWindowHours = r.Default_Reopen_Window_Hours__c;
    d.defaultCloseCooldownHours = r.Default_Close_Cooldown_Hours__c;
    d.pressureBlockEnabled = r.Pressure_Block_Enabled__c == true;
    d.pressureBlockThreshold = r.Pressure_Block_Threshold__c;
    d.rankingStrategy = r.Ranking_Strategy__c;
    d.engagementWeight = r.Engagement_Weight__c;
    d.engagementRangeMin = r.Engagement_Range_Min__c;
    d.engagementRangeMax = r.Engagement_Range_Max__c;
    d.randomSaltHours = r.Random_Salt_Hours__c;
    return d;
  }

  private static List<RuleDTO> loadRules() {
    List<RuleDTO> out = new List<RuleDTO>();
    for (Outreach_Rule__mdt r : [
      SELECT
        DeveloperName,
        MasterLabel,
        Rule_Id__c,
        Version__c,
        Display_Label__c,
        Description__c,
        Family__c,
        Need_Type__c,
        Category__c,
        Enabled__c,
        Shadow_Only__c,
        Bypass_Pressure_Gate__c,
        Override_Weekly_Queue_Cooldown__c,
        Override_Daily_Attempt_Limit__c,
        Force_Acknowledge__c,
        Use_Global_Cadence__c,
        Cadence_Policy__c,
        Served_Roles__c,
        Served_Teams__c,
        Required_Appointment_Types__c,
        Supersedes_Families__c,
        Recommended_Action__c,
        Action_Description__c,
        Sort_Order__c,
        Effective_Start__c,
        Effective_End__c,
        Communication_Topic__c,
        Communication_Class__c,
        Clinical_Priority__c,
        Counts_As_Outreach__c,
        Auto_Send_Email__c,
        Auto_Send_SMS__c
      FROM Outreach_Rule__mdt
      ORDER BY Sort_Order__c NULLS LAST, Rule_Id__c
    ]) {
      RuleDTO d = new RuleDTO();
      d.developerName = r.DeveloperName;
      d.masterLabel = r.MasterLabel;
      d.ruleId = r.Rule_Id__c;
      d.version = r.Version__c;
      d.displayLabel = r.Display_Label__c;
      d.description = r.Description__c;
      d.family = r.Family__c;
      d.needType = r.Need_Type__c;
      d.category = r.Category__c;
      d.enabled = r.Enabled__c == true;
      d.shadowOnly = r.Shadow_Only__c == true;
      d.bypassPressureGate = r.Bypass_Pressure_Gate__c == true;
      d.overrideWeeklyQueueCooldown = r.Override_Weekly_Queue_Cooldown__c == true;
      d.overrideDailyAttemptLimit = r.Override_Daily_Attempt_Limit__c == true;
      d.forceAcknowledge = r.Force_Acknowledge__c == true;
      d.useGlobalCadence = r.Use_Global_Cadence__c == true;
      d.cadencePolicy = r.Cadence_Policy__c;
      d.servedRoles = r.Served_Roles__c;
      d.servedTeams = r.Served_Teams__c;
      d.requiredAppointmentTypes = r.Required_Appointment_Types__c;
      d.supersedesFamilies = r.Supersedes_Families__c;
      d.recommendedAction = r.Recommended_Action__c;
      d.actionDescription = r.Action_Description__c;
      d.sortOrder = r.Sort_Order__c;
      d.effectiveStart = r.Effective_Start__c;
      d.effectiveEnd = r.Effective_End__c;
      d.communicationTopic = r.Communication_Topic__c;
      d.communicationClass = r.Communication_Class__c;
      d.clinicalPriority = r.Clinical_Priority__c == true;
      d.countsAsOutreach = r.Counts_As_Outreach__c == true;
      d.autoSendEmail = r.Auto_Send_Email__c == true;
      d.autoSendSms = r.Auto_Send_SMS__c == true;
      out.add(d);
    }
    return out;
  }

  private static List<CadenceDTO> loadCadence() {
    List<CadenceDTO> out = new List<CadenceDTO>();
    for (Cadence_Policy__mdt r : [
      SELECT
        DeveloperName,
        MasterLabel,
        Description__c,
        Max_Attempts__c,
        Attempt_Interval_Days__c,
        Pause_Duration_Days__c,
        Reopen_Window_Hours__c,
        Close_Cooldown_Hours__c,
        Override_Snooze__c,
        Reset_On_Promotion__c
      FROM Cadence_Policy__mdt
      ORDER BY DeveloperName
    ]) {
      CadenceDTO d = new CadenceDTO();
      d.developerName = r.DeveloperName;
      d.masterLabel = r.MasterLabel;
      d.description = r.Description__c;
      d.maxAttempts = r.Max_Attempts__c;
      d.attemptIntervalDays = r.Attempt_Interval_Days__c;
      d.pauseDurationDays = r.Pause_Duration_Days__c;
      d.reopenWindowHours = r.Reopen_Window_Hours__c;
      d.closeCooldownHours = r.Close_Cooldown_Hours__c;
      d.overrideSnooze = r.Override_Snooze__c == true;
      d.resetOnPromotion = r.Reset_On_Promotion__c == true;
      out.add(d);
    }
    return out;
  }

  private static RulesEngineDTO loadRulesEngine() {
    List<Outreach_RulesEngine_Settings__mdt> rows = [
      SELECT
        DeveloperName,
        MasterLabel,
        Enabled__c,
        Project_Slug__c,
        Surface_Decision_Key__c,
        Reaction_Decision_Key__c,
        Named_Credential__c,
        Batch_Size__c
      FROM Outreach_RulesEngine_Settings__mdt
      WHERE DeveloperName = 'Default'
      LIMIT 1
    ];
    if (rows.isEmpty())
      return null;
    Outreach_RulesEngine_Settings__mdt r = rows[0];
    RulesEngineDTO d = new RulesEngineDTO();
    d.developerName = r.DeveloperName;
    d.masterLabel = r.MasterLabel;
    d.enabled = r.Enabled__c == true;
    d.projectSlug = r.Project_Slug__c;
    d.surfaceDecisionKey = r.Surface_Decision_Key__c;
    d.reactionDecisionKey = r.Reaction_Decision_Key__c;
    d.namedCredential = r.Named_Credential__c;
    d.batchSize = r.Batch_Size__c;
    return d;
  }

  private static OmniDTO loadOmni() {
    List<Outreach_Omni_Settings__mdt> rows = [
      SELECT
        DeveloperName,
        MasterLabel,
        Enabled__c,
        Skill_Prefix__c,
        Service_Channel_Developer_Name__c,
        Routing_Config_Developer_Name__c
      FROM Outreach_Omni_Settings__mdt
      WHERE DeveloperName = 'Default'
      LIMIT 1
    ];
    if (rows.isEmpty())
      return null;
    Outreach_Omni_Settings__mdt r = rows[0];
    OmniDTO d = new OmniDTO();
    d.developerName = r.DeveloperName;
    d.masterLabel = r.MasterLabel;
    d.enabled = r.Enabled__c == true;
    d.skillPrefix = r.Skill_Prefix__c;
    d.serviceChannelDeveloperName = r.Service_Channel_Developer_Name__c;
    d.routingConfigDeveloperName = r.Routing_Config_Developer_Name__c;
    return d;
  }


  private static List<String> loadAppointmentTypes() {
    Set<String> values = new Set<String>();
    for (AggregateResult ar : [
      SELECT Type__c t
      FROM Appointment__c
      WHERE Type__c != NULL
      GROUP BY Type__c
      LIMIT 200
    ]) {
      String v = (String) ar.get('t');
      if (String.isNotBlank(v))
        values.add(v.trim());
    }
    List<String> out = new List<String>(values);
    out.sort();
    return out;
  }

  private static List<String> loadAvailableTeams(List<RuleDTO> rules) {
    Set<String> values = new Set<String>();
    for (AggregateResult ar : [
      SELECT MDM_Team__c teamName
      FROM User
      WHERE IsActive = TRUE AND MDM_Team__c != NULL
      GROUP BY MDM_Team__c
    ]) {
      String v = (String) ar.get('teamName');
      if (String.isNotBlank(v))
        values.add(v.trim());
    }
    if (rules != null) {
      for (RuleDTO r : rules)
        values.addAll(splitServedPreservingCase(r.servedTeams));
    }
    List<String> out = new List<String>(values);
    out.sort();
    return out;
  }

  private static List<String> loadAvailableRoles(List<RuleDTO> rules) {
    Set<String> values = new Set<String>();
    for (AggregateResult ar : [
      SELECT MDM_Role__c roleName
      FROM User
      WHERE IsActive = TRUE AND MDM_Role__c != NULL
      GROUP BY MDM_Role__c
    ]) {
      String v = (String) ar.get('roleName');
      if (String.isNotBlank(v))
        values.add(v.trim());
    }
    if (rules != null) {
      for (RuleDTO r : rules)
        values.addAll(splitServedPreservingCase(r.servedRoles));
    }
    List<String> out = new List<String>(values);
    out.sort();
    return out;
  }

  private static Set<String> splitServedPreservingCase(String raw) {
    Set<String> values = new Set<String>();
    if (String.isBlank(raw))
      return values;
    for (String part : raw.split('[;\n,]')) {
      if (String.isNotBlank(part))
        values.add(part.trim());
    }
    return values;
  }

  /** Persist as semicolon-separated list (AudienceSkillService.split). */
  private static String normalizeServedList(String raw) {
    if (String.isBlank(raw))
      return '';
    List<String> parts = new List<String>();
    Set<String> seen = new Set<String>();
    for (String part : raw.split('[;\n,]')) {
      String trimmed = part == null ? '' : part.trim();
      if (String.isBlank(trimmed))
        continue;
      String key = trimmed.toLowerCase();
      if (seen.contains(key))
        continue;
      seen.add(key);
      parts.add(trimmed);
    }
    return String.join(parts, ';');
  }

  private static Metadata.CustomMetadata baseCmd(String fullName, String label) {
    Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
    cmd.fullName = fullName;
    cmd.label = label;
    cmd.protected_x = false;
    return cmd;
  }

  private static void put(
    Metadata.CustomMetadata cmd,
    String field,
    Object value
  ) {
    Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
    v.field = field;
    v.value = value;
    cmd.values.add(v);
  }

  private static SaveResultDTO enqueue(
    Metadata.CustomMetadata cmd,
    String message
  ) {
    Metadata.DeployContainer container = new Metadata.DeployContainer();
    container.addMetadata(cmd);
    Id jobId = Metadata.Operations.enqueueDeployment(
      container,
      new OutreachConfigDeployCallback()
    );
    SaveResultDTO result = new SaveResultDTO();
    result.deployJobId = jobId;
    result.message = message;
    return result;
  }

  public class AccountSearchDTO {
    @AuraEnabled public Id accountId;
    @AuraEnabled public String name;
    @AuraEnabled public String sourceSystemId;
  }

  public class CommPreviewDTO {
    @AuraEnabled public Id accountId;
    @AuraEnabled public String accountName;
    @AuraEnabled public Boolean emailAllowed;
    @AuraEnabled public Boolean smsAllowed;
    @AuraEnabled public String emailReason;
    @AuraEnabled public String smsReason;
    @AuraEnabled public Boolean countsAsOutreach;
    @AuraEnabled public Boolean autoSendEmail;
    @AuraEnabled public Boolean autoSendSms;
    @AuraEnabled public String topicKey;
    @AuraEnabled public String emailSubject;
    @AuraEnabled public String emailBody;
    @AuraEnabled public String smsBody;
    @AuraEnabled public String preferenceCenterUrl;
    @AuraEnabled public String composeSource;
  }

  @AuraEnabled(cacheable=true)
  public static List<AccountSearchDTO> searchAccountsForPreview(String query) {
    requireConfigAccess();
    if (String.isBlank(query) || query.trim().length() < 2) {
      return new List<AccountSearchDTO>();
    }
    String q = query.trim();
    String likePat = '%' + q + '%';
    List<Account> rows = [
      SELECT Id, Name, SourceSystemIdentifier
      FROM Account
      WHERE IsPersonAccount = true
        AND (
          Name LIKE :likePat
          OR SourceSystemIdentifier = :q
          OR Source_System_ID_Search__c = :q
        )
      WITH USER_MODE
      ORDER BY Name
      LIMIT 25
    ];
    List<AccountSearchDTO> out = new List<AccountSearchDTO>();
    for (Account a : rows) {
      AccountSearchDTO d = new AccountSearchDTO();
      d.accountId = a.Id;
      d.name = a.Name;
      d.sourceSystemId = a.SourceSystemIdentifier;
      out.add(d);
    }
    return out;
  }

  @AuraEnabled
  public static CommPreviewDTO previewCareItemComm(Id accountId, String ruleId) {
    requireConfigAccess();
    return OutreachCommPreviewService.preview(accountId, ruleId);
  }


}
