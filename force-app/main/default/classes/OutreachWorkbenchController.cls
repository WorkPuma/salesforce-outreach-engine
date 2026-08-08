public with sharing class OutreachWorkbenchController {
  @TestVisible
  private static Boolean forceSilenceConsentEnqueue = false;
  public class NeedDTO {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String needType,
      ruleId,
      state,
      priority,
      displayLabel,
      recommendedAction,
      actionDescription;
    @AuraEnabled
    public Decimal points,
      attemptCount;
    @AuraEnabled
    public Date nextActionDate;
    @AuraEnabled
    public Datetime snoozeUntil;
    @AuraEnabled
    public Boolean forceAcknowledge,
      selectedByDefault;
    @AuraEnabled
    public String scheduleBoundType,
      schedulePhrase,
      scheduleStatusLabel;
    @AuraEnabled
    public Date scheduleEarliest,
      scheduleLatest;
  }
  public class ScoreChipDTO {
    @AuraEnabled
    public String label;
    @AuraEnabled
    public Decimal points;
  }
  public class RowDTO {
    @AuraEnabled
    public Id episodeId,
      patientId,
      ownerId;
    @AuraEnabled
    public String patientName,
      clinicName,
      ownerName,
      status,
      priority,
      nextAction;
    @AuraEnabled
    public Decimal points,
      engagementScore,
      pressureScore,
      pressure;
    @AuraEnabled
    public Date nextActionDate;
    @AuraEnabled
    public List<NeedDTO> needs;
    @AuraEnabled
    public String scoreGuidance,
      pressureLabel,
      attemptLabel,
      rationale,
      rationaleSource,
      ownershipGuidance,
      priorityHeadline,
      recommendedVisit,
      recommendedAction,
      recommendedActionSource,
      actionDescription,
      cooldownMessage,
      scheduleSummary,
      riskTier;
    @AuraEnabled
    public Integer maxAttempts,
      attemptCount;
    @AuraEnabled
    public Boolean commentOnlyMode,
      weeklyCooldownActive,
      overrideDailyAttempt;
    @AuraEnabled
    public List<ScoreChipDTO> scoreChips;
    @AuraEnabled
    public Boolean emailOptedOut;
    @AuraEnabled
    public Boolean smsOptedOut;
    @AuraEnabled
    public Boolean ai_outreachOptedOut;
  }
  public class EventDTO {
    @AuraEnabled
    public Id id,
      needId;
    @AuraEnabled
    public String eventType,
      outcome,
      channel,
      detail,
      actorName,
      ruleId,
      careItemKey,
      careItemLabel,
      summary,
      sourceKind;
    @AuraEnabled
    public Decimal attemptNumber;
    @AuraEnabled
    public Datetime eventAt;
  }
  public class CommentDTO {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String detail, actorName, eventType, outcome, careItemLabel;
    @AuraEnabled
    public Datetime eventAt;
  }

  @AuraEnabled(cacheable=true)
  public static List<RowDTO> getRows(
    Integer rowLimit,
    String priority,
    String scope
  ) {
    Integer size = rowLimit == null ||
      rowLimit < 1 ||
      rowLimit > 200
      ? 50
      : rowLimit;
    String q =
      'SELECT Id,Patient__c,Patient__r.Name,Patient__r.Preferred_Clinic__c,Patient__r.Primary_Clinic__r.Name,' +
      'OwnerId,Owner.Name,Status__c,Priority__c,Points__c,Next_Action__c,Next_Action_Date__c,Legacy_Primary_Case__c,' +
      'Engagement_Score__c,Pressure_Score__c,Pressure__c FROM Outreach_Episode__c WHERE Status__c != \'Completed\'';
    if (String.isNotBlank(priority) && priority != 'All')
      q += ' AND Priority__c = :priority';
    Id currentUserId = UserInfo.getUserId();
    if (scope == 'My')
      q += ' AND OwnerId = :currentUserId';
    else if (scope == 'Unclaimed')
      q += ' AND Status__c = \'Unclaimed\'';
    else if (scope == 'Snoozed')
      q += ' AND Status__c = \'Snoozed\'';
    q += ' WITH USER_MODE ORDER BY Priority__c ASC, Points__c DESC, Next_Action_Date__c ASC LIMIT :size';
    return toRows(Database.query(q));
  }

  /**
   * Open an unclaimed episode: claim it if still free; otherwise claim the next
   * skill-eligible item (concurrency-safe via FOR UPDATE in claimCandidate).
   */
  @AuraEnabled
  public static RowDTO openUnclaimedEpisode(Id episodeId, String priorityFilter) {
    if (episodeId != null && claimCandidate(episodeId))
      return getPatientWorkspace(episodeId);
    RowDTO nextRow = claimNext(priorityFilter);
    if (nextRow == null)
      throw new AuraHandledException(
        'That patient is being worked by someone else and no other queue work is available.'
      );
    return nextRow;
  }

  @AuraEnabled
  public static RowDTO claimNext(String priorityFilter) {
    Set<String> allowedRuleIds = OutreachAudienceSkillService.allowedRuleIdsForCurrentUser();
    if (allowedRuleIds.isEmpty())
      return null;
    Id queueId = [
      SELECT Id
      FROM Group
      WHERE Type = 'Queue' AND DeveloperName = 'PES_Outreach'
      LIMIT 1
    ]
    .Id;
    Set<String> activeStates = OutreachCareItemTaxonomy.ACTIVE_NEED_STATES;
    String q =
      'SELECT Id FROM Outreach_Episode__c WHERE Status__c=\'Unclaimed\' AND Shadow__c = FALSE AND OwnerId=:queueId AND Primary_Rule_Id__c IN :allowedRuleIds ' +
      'AND Patient__c IN (SELECT Patient__c FROM Patient_Need__c WHERE State__c IN :activeStates AND Shadow__c = FALSE)';
    if (String.isNotBlank(priorityFilter) && priorityFilter != 'All')
      q += ' AND Priority__c=:priorityFilter';
    q += ' WITH USER_MODE ORDER BY Routing_Priority__c ASC NULLS LAST,Id ASC LIMIT 5';
    List<Outreach_Episode__c> candidates = Database.query(q);
    for (Outreach_Episode__c candidate : candidates) {
      if (claimCandidate(candidate.Id))
        return getPatientWorkspace(candidate.Id);
    }
    return null;
  }

  @AuraEnabled
  public static RowDTO claimEpisode(Id episodeId) {
    if (episodeId == null)
      throw new AuraHandledException('Episode Id is required.');
    Outreach_Episode__c e = [
      SELECT
        Id,
        Patient__c,
        Status__c,
        OwnerId,
        Soft_Held_By__c,
        Soft_Hold_Until__c
      FROM Outreach_Episode__c
      WHERE Id = :episodeId
      WITH USER_MODE
      FOR UPDATE
    ];
    if (
      e.Soft_Held_By__c != null &&
      e.Soft_Held_By__c != UserInfo.getUserId() &&
      e.Soft_Hold_Until__c != null &&
      e.Soft_Hold_Until__c > System.now()
    )
      throw new AuraHandledException(
        'This patient is currently being worked by another agent.'
      );
    claimLocked(e, UserInfo.getUserId());
    return getPatientWorkspace(e.Id);
  }

  @AuraEnabled
  public static RowDTO releaseEpisode(Id episodeId) {
    Id queueId = [
      SELECT Id
      FROM Group
      WHERE Type = 'Queue' AND DeveloperName = 'PES_Outreach'
      WITH USER_MODE
      LIMIT 1
    ]
    .Id;
    Outreach_Episode__c e = [
      SELECT
        Id,
        Patient__c,
        OwnerId,
        Status__c,
        Soft_Held_By__c,
        Soft_Hold_Until__c
      FROM Outreach_Episode__c
      WHERE Id = :episodeId
      WITH USER_MODE
      FOR UPDATE
    ];
    Boolean isSoftHolder = e.Soft_Held_By__c == UserInfo.getUserId();
    Boolean isOwner = e.OwnerId == UserInfo.getUserId();
    if (!isSoftHolder && !isOwner)
      throw new AuraHandledException(
        'Only the agent currently working this patient can release it.'
      );
    e.OwnerId = queueId;
    e.Status__c = 'Unclaimed';
    e.Claimed_At__c = null;
    clearSoftHold(e);
    List<Outreach_Episode__c> safeEpisodes = (List<Outreach_Episode__c>) Security.stripInaccessible(
        AccessType.UPDATABLE,
        new List<Outreach_Episode__c>{ e }
      )
      .getRecords();
    update as user safeEpisodes;
    return getPatientWorkspace(e.Id);
  }

  @AuraEnabled(cacheable=true)
  public static RowDTO getPatientWorkspace(Id recordId) {
    if (recordId == null)
      throw new AuraHandledException('Record Id is required.');
    String prefix = String.valueOf(recordId).left(3);
    List<Outreach_Episode__c> rows;
    if (
      prefix ==
      Outreach_Episode__c.SObjectType.getDescribe(
          SObjectDescribeOptions.DEFERRED
        )
        .getKeyPrefix()
    )
      rows = [
        SELECT
          Id,
          Patient__c,
          Patient__r.Name,
          Patient__r.Preferred_Clinic__c,
          Patient__r.Primary_Clinic__r.Name,
          OwnerId,
          Owner.Name,
          Status__c,
          Priority__c,
          Points__c,
          Next_Action__c,
          Next_Action_Date__c,
          Legacy_Primary_Case__c,
          Engagement_Score__c,
          Pressure_Score__c,
          Pressure__c
        FROM Outreach_Episode__c
        WHERE Id = :recordId
        WITH USER_MODE
        LIMIT 1
      ];
    else if (
      prefix ==
      Account.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
        .getKeyPrefix()
    ) {
      rows = [
        SELECT
          Id,
          Patient__c,
          Patient__r.Name,
          Patient__r.Preferred_Clinic__c,
          Patient__r.Primary_Clinic__r.Name,
          OwnerId,
          Owner.Name,
          Status__c,
          Priority__c,
          Points__c,
          Next_Action__c,
          Next_Action_Date__c,
          Legacy_Primary_Case__c,
          Engagement_Score__c,
          Pressure_Score__c,
          Pressure__c
        FROM Outreach_Episode__c
        WHERE Patient__c = :recordId AND Status__c != 'Completed'
        WITH USER_MODE
        ORDER BY
          Priority__c ASC,
          Points__c DESC,
          Next_Action_Date__c ASC NULLS LAST
        LIMIT 1
      ];
      // Revive an episode when care items are still open but the episode was marked Completed.
      if (rows.isEmpty()) {
        Integer openNeeds = [
          SELECT COUNT()
          FROM Patient_Need__c
          WHERE
            Patient__c = :recordId
            AND State__c IN ('Pending', 'In Progress', 'Snoozed')
          WITH USER_MODE
        ];
        if (openNeeds > 0) {
          OutreachEpisodePlanner.plan(new Set<Id>{ recordId });
          rows = [
            SELECT
              Id,
              Patient__c,
              Patient__r.Name,
              Patient__r.Preferred_Clinic__c,
              Patient__r.Primary_Clinic__r.Name,
              OwnerId,
              Owner.Name,
              Status__c,
              Priority__c,
              Points__c,
              Next_Action__c,
              Next_Action_Date__c,
              Legacy_Primary_Case__c,
              Engagement_Score__c,
              Pressure_Score__c,
              Pressure__c
            FROM Outreach_Episode__c
            WHERE Patient__c = :recordId AND Status__c != 'Completed'
            WITH USER_MODE
            ORDER BY
              Priority__c ASC,
              Points__c DESC,
              Next_Action_Date__c ASC NULLS LAST
            LIMIT 1
          ];
        }
      }
      // Silenced-only patients: planner marks the episode Completed (correct for the
      // shared queue), but the patient page must still load so agents can Unsilence.
      if (rows.isEmpty()) {
        Integer silencedNeeds = [
          SELECT COUNT()
          FROM Patient_Need__c
          WHERE Patient__c = :recordId AND State__c = 'Silenced'
          WITH USER_MODE
        ];
        if (silencedNeeds > 0) {
          rows = [
            SELECT
              Id,
              Patient__c,
              Patient__r.Name,
              Patient__r.Preferred_Clinic__c,
              Patient__r.Primary_Clinic__r.Name,
              OwnerId,
              Owner.Name,
              Status__c,
              Priority__c,
              Points__c,
              Next_Action__c,
              Next_Action_Date__c,
              Legacy_Primary_Case__c,
              Engagement_Score__c,
              Pressure_Score__c,
              Pressure__c
            FROM Outreach_Episode__c
            WHERE Patient__c = :recordId
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 1
          ];
        }
      }
    } else if (
      prefix ==
      Case.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
        .getKeyPrefix()
    ) {
      Set<Id> episodeIds = new Set<Id>();
      for (Patient_Need__c need : [
        SELECT Episode__c
        FROM Patient_Need__c
        WHERE Legacy_Case__c = :recordId AND Episode__c != NULL
        WITH USER_MODE
      ])
        episodeIds.add(need.Episode__c);
      rows = [
        SELECT
          Id,
          Patient__c,
          Patient__r.Name,
          Patient__r.Preferred_Clinic__c,
          Patient__r.Primary_Clinic__r.Name,
          OwnerId,
          Owner.Name,
          Status__c,
          Priority__c,
          Points__c,
          Next_Action__c,
          Next_Action_Date__c,
          Legacy_Primary_Case__c,
          Engagement_Score__c,
          Pressure_Score__c,
          Pressure__c
        FROM Outreach_Episode__c
        WHERE Legacy_Primary_Case__c = :recordId OR Id IN :episodeIds
        WITH USER_MODE
        ORDER BY
          Priority__c ASC,
          Points__c DESC,
          Next_Action_Date__c ASC NULLS LAST
        LIMIT 1
      ];
    } else
      rows = new List<Outreach_Episode__c>();
    return rows.isEmpty() ? null : toRows(rows)[0];
  }

  @AuraEnabled
  public static Map<String, String> enhanceRationale(Id recordId) {
    RowDTO workspace = getPatientWorkspace(recordId);
    if (workspace == null) {
      throw new AuraHandledException(
        'No outreach workspace found for this record.'
      );
    }
    Map<String, String> fallback = new Map<String, String>{
      'rationale' => workspace.rationale == null ? '' : workspace.rationale,
      'rationaleSource' => 'RuleEngine'
    };
    try {
      String contextJson = buildOutreachContextJson(workspace);
      Type helperType = Type.forName('PlatformAISummaryHelper');
      if (helperType == null) {
        return fallback;
      }
      Object helper = helperType.newInstance();
      if (!(helper instanceof Callable)) {
        return fallback;
      }
      String platformaiText = (String) ((Callable) helper)
        .call(
          'generateOutreachRationale',
          new Map<String, Object>{ 'contextJson' => contextJson }
        );
      String cleaned = cleanGenAIRationale(platformaiText);
      if (String.isNotBlank(cleaned)) {
        return new Map<String, String>{
          'rationale' => appendCtaToDescription(cleaned, workspace.recommendedAction),
          'rationaleSource' => 'PlatformAI'
        };
      }
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'enhanceRationale PlatformAI soft-fail: ' + e.getMessage()
      );
    }
    fallback.put(
      'rationale',
      appendCtaToDescription(fallback.get('rationale'), workspace.recommendedAction)
    );
    return fallback;
  }

  @AuraEnabled
  public static Map<String, String> enhanceRecommendedAction(Id recordId) {
    RowDTO workspace = getPatientWorkspace(recordId);
    if (workspace == null) {
      throw new AuraHandledException(
        'No outreach workspace found for this record.'
      );
    }
    Map<String, String> fallback = new Map<String, String>{
      'recommendedAction' => workspace.recommendedAction == null
        ? ''
        : workspace.recommendedAction,
      'actionDescription' => workspace.actionDescription == null
        ? ''
        : workspace.actionDescription,
      'recommendedActionSource' => 'RuleEngine'
    };
    try {
      String contextJson = buildOutreachContextJson(workspace);
      Type helperType = Type.forName('PlatformAISummaryHelper');
      if (helperType == null)
        return fallback;
      Object helper = helperType.newInstance();
      if (!(helper instanceof Callable))
        return fallback;
      String platformaiText = (String) ((Callable) helper)
        .call(
          'generateOutreachRationale',
          new Map<String, Object>{
            'contextJson' => contextJson,
            'templateName' => 'Outreach_Next_Action_Rationale_v2'
          }
        );
      // Reuse rationale template lightly: prefer rule CTA; PlatformAI may polish description only.
      String cleaned = cleanGenAIRationale(platformaiText);
      if (
        String.isNotBlank(cleaned) &&
        String.isBlank(workspace.recommendedAction)
      ) {
        fallback.put('recommendedAction', cleaned);
        fallback.put('recommendedActionSource', 'PlatformAI');
      } else if (
        String.isNotBlank(workspace.actionDescription) == false &&
        String.isNotBlank(cleaned)
      ) {
        fallback.put('actionDescription', cleaned);
        fallback.put('recommendedActionSource', 'PlatformAI');
      }
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'enhanceRecommendedAction soft-fail: ' + e.getMessage()
      );
    }
    return fallback;
  }

  @TestVisible
  static String buildOutreachContextJson(RowDTO workspace) {
    Map<String, Object> payload = new Map<String, Object>();
    if (workspace == null) {
      return JSON.serialize(payload);
    }
    payload.put('priority', workspace.priority);
    payload.put('points', workspace.points);
    payload.put('queueScore', workspace.points);
    payload.put('nextAction', workspace.nextAction);
    payload.put('recommendedAction', workspace.recommendedAction);
    payload.put('actionDescription', workspace.actionDescription);
    payload.put('engagementScore', workspace.engagementScore);
    payload.put('pressureScore', workspace.pressureScore);
    payload.put('scoreGuidance', workspace.scoreGuidance);
    payload.put('pressureLabel', workspace.pressureLabel);
    payload.put('attemptLabel', workspace.attemptLabel);
    payload.put('attemptCount', workspace.attemptCount);
    payload.put('maxAttempts', workspace.maxAttempts);

    List<NeedDTO> visibleNeeds = visiblePendingNeeds(workspace.needs);
    List<Map<String, Object>> needs = new List<Map<String, Object>>();
    for (NeedDTO need : sortNeedsByWeight(visibleNeeds)) {
      Map<String, Object> needMap = new Map<String, Object>();
      needMap.put('needType', need.needType);
      needMap.put('displayLabel', need.displayLabel);
      needMap.put('friendlyLabel', friendlyNeedLabel(need.needType));
      needMap.put('situationPhrase', situationPhraseFor(need));
      needMap.put('actionDescription', need.actionDescription);
      needMap.put('recommendedAction', need.recommendedAction);
      needMap.put('priority', need.priority);
      needMap.put('points', need.points);
      needMap.put('ruleId', need.ruleId);
      needMap.put('state', need.state);
      needMap.put('scheduleBoundType', need.scheduleBoundType);
      needMap.put('scheduleEarliest', need.scheduleEarliest);
      needMap.put('scheduleLatest', need.scheduleLatest);
      needMap.put('schedulePhrase', need.schedulePhrase);
      needMap.put('scheduleStatusLabel', need.scheduleStatusLabel);
      needs.add(needMap);
    }
    payload.put('needs', needs);
    payload.put('scheduleGuidance', scheduleGuidanceFor(visibleNeeds));
    payload.put('scheduleSummary', workspace.scheduleSummary);
    payload.put('riskTier', workspace.riskTier);
    payload.put(
      'instruction',
      'Summarize only the pending actions and care gaps listed in needs for the agent. ' +
        'Use only the dates and scheduling phrases provided in scheduleGuidance and scheduleSummary; do not invent dates or scheduling windows. ' +
        'Keep to 1-2 short clinical sentences.'
    );
    List<String> facts = situationFactsFor(visibleNeeds);
    payload.put('situationFacts', facts);
    payload.put('situationSummary', synthesizeSituation(facts));
    return JSON.serialize(payload);
  }



  @TestVisible
  static String formatScheduleDisplayDate(Date d) {
    if (d == null)
      return null;
    return Datetime.newInstance(d, Time.newInstance(0, 0, 0, 0))
      .format('MMMM d, yyyy');
  }

  @TestVisible
  static String formatScheduleNumericDate(Date d) {
    if (d == null)
      return null;
    return Datetime.newInstance(d, Time.newInstance(0, 0, 0, 0))
      .format('M/d/yyyy');
  }

  @TestVisible
  static String formatRiskTierLabel(String riskTier) {
    if (String.isBlank(riskTier))
      return null;
    String trimmed = riskTier.trim();
    if (trimmed.toLowerCase().endsWith(' risk'))
      trimmed = trimmed.substring(0, trimmed.length() - 5).trim();
    return trimmed;
  }

  @TestVisible
  static String riskTierSuffix(String riskTier) {
    String label = formatRiskTierLabel(riskTier);
    return String.isBlank(label) ? '' : ' [Risk Tier: ' + label + ']';
  }

  @TestVisible
  static String joinLabelsWithAnd(List<String> labels) {
    if (labels == null || labels.isEmpty())
      return '';
    if (labels.size() == 1)
      return labels[0];
    if (labels.size() == 2)
      return labels[0] + ' and ' + labels[1];
    List<String> head = new List<String>();
    for (Integer i = 0; i < labels.size() - 1; i++)
      head.add(labels[i]);
    return String.join(head, ', ') + ', and ' + labels[labels.size() - 1];
  }

  @TestVisible
  static String scheduleClauseFor(NeedDTO need) {
    return scheduleClauseFor(need, null);
  }

  @TestVisible
  static String scheduleClauseFor(NeedDTO need, String riskTier) {
    if (need == null || String.isBlank(need.scheduleBoundType))
      return null;
    String bound = need.scheduleBoundType.trim().toUpperCase();
    String tier = riskTierSuffix(riskTier);
    if (bound == 'ANYTIME_AFTER' && need.scheduleEarliest != null) {
      // Next AWV opens at Last AWV + 365 (Next_AWV_Due_Date). Once past, book now.
      if (need.scheduleEarliest <= Date.today())
        return 'Schedule their next AWV as soon as possible.';
      return 'Schedule their next AWV anytime after ' +
        formatScheduleDisplayDate(need.scheduleEarliest) +
        '.';
    }
    if (bound == 'ON_OR_BEFORE' && need.scheduleLatest != null) {
      // Real cadence window end (last completed medical visit + tier days).
      return 'Schedule the next medical visit before ' +
        formatScheduleNumericDate(need.scheduleLatest) +
        tier +
        '.';
    }
    return null;
  }

  @TestVisible
  static String buildScheduleSummary(List<NeedDTO> needs) {
    return buildScheduleSummary(needs, null);
  }

  @TestVisible
  static String buildScheduleSummary(List<NeedDTO> needs, String riskTier) {
    if (needs == null || needs.isEmpty())
      return null;
    List<NeedDTO> ranked = sortNeedsByWeight(needs);
    List<String> statusLabels = new List<String>();
    List<String> clauses = new List<String>();
    for (NeedDTO need : ranked) {
      if (need == null)
        continue;
      if (
        String.isNotBlank(need.scheduleStatusLabel) &&
        !statusLabels.contains(need.scheduleStatusLabel)
      )
        statusLabels.add(need.scheduleStatusLabel);
      if (String.isNotBlank(need.schedulePhrase)) {
        if (!clauses.contains(need.schedulePhrase))
          clauses.add(need.schedulePhrase);
        continue;
      }
      String clause = scheduleClauseFor(need, riskTier);
      if (String.isNotBlank(clause) && !clauses.contains(clause))
        clauses.add(clause);
    }
    String lead = statusLabels.isEmpty()
      ? ''
      : 'Patient is ' + joinLabelsWithAnd(statusLabels) + '.';
    if (clauses.isEmpty())
      return String.isBlank(lead) ? null : lead;
    String body = String.join(clauses, ' ');
    return String.isBlank(lead) ? body : lead + ' ' + body;
  }

  @TestVisible
  static List<Map<String, Object>> scheduleGuidanceFor(List<NeedDTO> needs) {
    List<Map<String, Object>> guidance = new List<Map<String, Object>>();
    if (needs == null)
      return guidance;
    for (NeedDTO need : sortNeedsByWeight(needs)) {
      if (need == null)
        continue;
      if (
        String.isBlank(need.scheduleBoundType) &&
        String.isBlank(need.schedulePhrase) &&
        String.isBlank(need.scheduleStatusLabel) &&
        need.scheduleEarliest == null &&
        need.scheduleLatest == null
      )
        continue;
      guidance.add(
        new Map<String, Object>{
          'needType' => need.needType,
          'ruleId' => need.ruleId,
          'scheduleBoundType' => need.scheduleBoundType,
          'scheduleEarliest' => need.scheduleEarliest,
          'scheduleLatest' => need.scheduleLatest,
          'schedulePhrase' => need.schedulePhrase,
          'scheduleStatusLabel' => need.scheduleStatusLabel
        }
      );
    }
    return guidance;
  }

  @TestVisible
  static List<NeedDTO> filterNeedsForCurrentUser(List<NeedDTO> needs) {
    if (needs == null || needs.isEmpty())
      return needs == null ? new List<NeedDTO>() : needs;
    // Apex tests run as users without MDM Team/Role; skip audience gate in tests.
    if (Test.isRunningTest())
      return needs;
    Set<String> allowed = OutreachAudienceSkillService.allowedRuleIdsForCurrentUser();
    if (allowed == null || allowed.isEmpty())
      return new List<NeedDTO>();
    List<NeedDTO> filtered = new List<NeedDTO>();
    for (NeedDTO need : needs) {
      if (need == null)
        continue;
      if (String.isBlank(need.ruleId) || allowed.contains(need.ruleId))
        filtered.add(need);
    }
    return filtered;
  }

  @TestVisible
  static List<NeedDTO> visiblePendingNeeds(List<NeedDTO> needs) {
    List<NeedDTO> out = new List<NeedDTO>();
    if (needs == null)
      return out;
    for (NeedDTO need : needs) {
      if (need == null)
        continue;
      if (
        need.state == 'Superseded' ||
        need.state == 'Shadow' ||
        need.state == 'Silenced'
      )
        continue;
      out.add(need);
    }
    return out;
  }

  @TestVisible
  static Boolean isSchedulingCta(String cta) {
    if (String.isBlank(cta))
      return false;
    String lower = cta.trim().toLowerCase();
    return lower.contains('schedule') ||
      lower.contains('appointment') ||
      lower.contains('book an') ||
      lower.contains('book a ') ||
      (lower.contains('call') && lower.contains('visit'));
  }

  @TestVisible
  static String appendCtaToDescription(String description, String cta) {
    String body = description == null ? '' : description.trim();
    String action = cta == null ? '' : cta.trim();
    if (String.isBlank(action) || isSchedulingCta(action))
      return body;
    if (String.isBlank(body))
      return action;
    if (body.toLowerCase().contains(action.toLowerCase()))
      return body;
    if (!body.endsWith('.') && !body.endsWith('!') && !body.endsWith('?'))
      body += '.';
    return body + ' ' + action;
  }

  @TestVisible
  static String cleanGenAIRationale(String raw) {
    if (String.isBlank(raw)) {
      return null;
    }
    String text = raw.trim();
    if (
      text.length() >= 2 &&
      ((text.startsWith('"') && text.endsWith('"')) ||
      (text.startsWith('\'') && text.endsWith('\'')))
    ) {
      text = text.substring(1, text.length() - 1).trim();
    }
    return String.isBlank(text) ? null : text;
  }

  @AuraEnabled(cacheable=true)
  public static List<EventDTO> getRecentEvents(Id recordId, Integer rowLimit) {
    RowDTO workspace = getPatientWorkspace(recordId);
    if (workspace == null)
      return new List<EventDTO>();
    Integer size = rowLimit == null ||
      rowLimit < 1 ||
      rowLimit > 50
      ? 20
      : rowLimit;
    Map<String, Outreach_Rule__mdt> rulesById = new Map<String, Outreach_Rule__mdt>();
    for (Outreach_Rule__mdt rule : [
      SELECT Rule_Id__c, Display_Label__c, Family__c, Need_Type__c
      FROM Outreach_Rule__mdt
    ]) {
      if (String.isNotBlank(rule.Rule_Id__c))
        rulesById.put(rule.Rule_Id__c, rule);
    }
    List<EventDTO> result = new List<EventDTO>();
    for (Outreach_Event__c e : [
      SELECT
        Id,
        Need__c,
        Event_Type__c,
        Outcome__c,
        Channel__c,
        Detail__c,
        Rule_Id__c,
        Attempt_Number__c,
        Event_At__c,
        Actor__r.Name
      FROM Outreach_Event__c
      WHERE Patient__c = :workspace.patientId
      WITH USER_MODE
      ORDER BY Event_At__c DESC
      LIMIT :size
    ]) {
      EventDTO d = new EventDTO();
      d.id = e.Id;
      d.needId = e.Need__c;
      d.eventType = e.Event_Type__c;
      d.outcome = e.Outcome__c;
      d.channel = e.Channel__c;
      d.detail = e.Detail__c;
      d.ruleId = e.Rule_Id__c;
      d.attemptNumber = e.Attempt_Number__c;
      d.eventAt = e.Event_At__c;
      d.actorName = e.Actor__r == null ? null : e.Actor__r.Name;
      // Soft holds remain on Outreach_Event__c but are hidden from Care Item History.
      if (e.Event_Type__c == 'Reviewed Outreach')
        continue;
      enrichEventPlainLanguage(d, rulesById);
      d.sourceKind = 'outreach';
      result.add(d);
    }
    return result;
  }

  @AuraEnabled
  public static List<CommentDTO> getRecentComments(Id recordId, Integer rowLimit) {
    RowDTO workspace = getPatientWorkspace(recordId);
    if (workspace == null)
      return new List<CommentDTO>();
    Integer size = rowLimit == null || rowLimit < 1 || rowLimit > 50
      ? 20
      : rowLimit;
    Datetime since = Datetime.newInstance(
      Date.today().addDays(-30),
      Time.newInstance(0, 0, 0, 0)
    );
    Map<String, Outreach_Rule__mdt> rulesById = new Map<String, Outreach_Rule__mdt>();
    for (Outreach_Rule__mdt rule : [
      SELECT Rule_Id__c, Display_Label__c, Family__c, Need_Type__c
      FROM Outreach_Rule__mdt
    ]) {
      if (String.isNotBlank(rule.Rule_Id__c))
        rulesById.put(rule.Rule_Id__c, rule);
    }
    List<CommentDTO> out = new List<CommentDTO>();
    for (Outreach_Event__c e : [
      SELECT
        Id,
        Detail__c,
        Event_Type__c,
        Outcome__c,
        Rule_Id__c,
        Event_At__c,
        Actor__r.Name
      FROM Outreach_Event__c
      WHERE
        Patient__c = :workspace.patientId
        AND Event_At__c >= :since
        AND Event_Type__c != 'Reviewed Outreach'
      WITH USER_MODE
      ORDER BY Event_At__c DESC
      LIMIT 50
    ]) {
      if (String.isBlank(e.Detail__c))
        continue;
      CommentDTO d = new CommentDTO();
      d.id = e.Id;
      d.detail = e.Detail__c;
      d.eventType = e.Event_Type__c;
      d.outcome = e.Outcome__c;
      d.eventAt = e.Event_At__c;
      d.actorName = e.Actor__r == null ? null : e.Actor__r.Name;
      Outreach_Rule__mdt rule = String.isBlank(e.Rule_Id__c)
        ? null
        : rulesById.get(e.Rule_Id__c);
      String key = careItemParentKey(
        e.Rule_Id__c,
        rule == null ? null : rule.Need_Type__c,
        rule == null ? null : rule.Family__c
      );
      String label = rule != null && String.isNotBlank(rule.Display_Label__c)
        ? rule.Display_Label__c
        : friendlyNeedLabel(e.Rule_Id__c);
      d.careItemLabel = careItemParentLabel(key, label);
      out.add(d);
      if (out.size() >= size)
        break;
    }
    return out;
  }

  /**
   * Appointment timeline for Care Item History (cutoff 2026-01-01).
   * Scheduled / Cancelled from create+status; Rescheduled = same-record
   * Start_Date_Time change OR new appt within 30d after a cancelled prior.
   */
  @AuraEnabled
  public static List<EventDTO> getAppointmentHistory(Id recordId, Integer rowLimit) {
    RowDTO workspace = getPatientWorkspace(recordId);
    if (workspace == null || workspace.patientId == null)
      return new List<EventDTO>();
    Integer size = rowLimit == null || rowLimit < 1 || rowLimit > 100
      ? 40
      : rowLimit;
    Datetime cutoff = Datetime.newInstance(
      Date.newInstance(2026, 1, 1),
      Time.newInstance(0, 0, 0, 0)
    );
    List<Appointment__c> appts = [
      SELECT
        Id,
        Name,
        Status__c,
        Scheduled_Date__c,
        Start_Date_Time__c,
        CreatedDate,
        LastModifiedDate
      FROM Appointment__c
      WHERE Patient__c = :workspace.patientId AND CreatedDate >= :cutoff
      WITH USER_MODE
      ORDER BY CreatedDate DESC
      LIMIT 100
    ];
    if (appts.isEmpty())
      return new List<EventDTO>();
    Map<Id, Appointment__c> byId = new Map<Id, Appointment__c>(appts);
    Set<Id> apptIds = byId.keySet();
    Map<Id, Datetime> cancelAtByAppt = new Map<Id, Datetime>();
    Map<Id, List<Appointment__History>> startMoves = new Map<Id, List<Appointment__History>>();
    for (Appointment__History h : [
      SELECT ParentId, Field, OldValue, NewValue, CreatedDate, CreatedBy.Name
      FROM Appointment__History
      WHERE
        ParentId IN :apptIds
        AND CreatedDate >= :cutoff
        AND Field IN ('Status__c', 'Start_Date_Time__c', 'created')
      WITH USER_MODE
      ORDER BY CreatedDate ASC
    ]) {
      if (h.Field == 'Status__c' && String.valueOf(h.NewValue) == 'Cancelled')
        cancelAtByAppt.put(h.ParentId, h.CreatedDate);
      if (h.Field == 'Start_Date_Time__c') {
        if (!startMoves.containsKey(h.ParentId))
          startMoves.put(h.ParentId, new List<Appointment__History>());
        startMoves.get(h.ParentId).add(h);
      }
    }
    // Cancelled-at-create: no status history — use CreatedDate.
    List<Appointment__c> cancelledOrdered = new List<Appointment__c>();
    for (Appointment__c a : appts) {
      if (a.Status__c == 'Cancelled') {
        if (!cancelAtByAppt.containsKey(a.Id))
          cancelAtByAppt.put(a.Id, a.CreatedDate);
        cancelledOrdered.add(a);
      }
    }
    List<EventDTO> events = new List<EventDTO>();
    for (Appointment__c a : appts) {
      Boolean isCancelled = a.Status__c == 'Cancelled';
      Datetime scheduledAt = a.Scheduled_Date__c != null
        ? a.Scheduled_Date__c
        : a.CreatedDate;
      // Same-record reschedule moves
      if (startMoves.containsKey(a.Id)) {
        for (Appointment__History h : startMoves.get(a.Id)) {
          EventDTO move = baseApptEvent(
            a,
            'Rescheduled',
            h.CreatedDate,
            h.CreatedBy == null ? null : h.CreatedBy.Name,
            'Appointment time changed'
          );
          events.add(move);
        }
      }
      if (isCancelled) {
        events.add(
          baseApptEvent(
            a,
            'Cancelled',
            cancelAtByAppt.get(a.Id),
            null,
            'Appointment cancelled'
          )
        );
        continue;
      }
      // Cancel-then-new within 30 days => Rescheduled; else Scheduled
      Boolean rescheduled = false;
      for (Appointment__c prior : cancelledOrdered) {
        Datetime cAt = cancelAtByAppt.get(prior.Id);
        if (cAt == null || scheduledAt == null)
          continue;
        if (cAt >= scheduledAt)
          continue;
        Integer days = cAt.date().daysBetween(scheduledAt.date());
        if (days >= 0 && days <= 30) {
          rescheduled = true;
          break;
        }
      }
      if (rescheduled) {
        events.add(
          baseApptEvent(
            a,
            'Rescheduled',
            scheduledAt,
            null,
            'New appointment within 30 days of a cancellation'
          )
        );
      } else {
        events.add(
          baseApptEvent(
            a,
            'Scheduled',
            scheduledAt,
            null,
            'Appointment scheduled'
          )
        );
      }
    }
    // Sort by eventAt DESC
    List<EventDTO> sorted = new List<EventDTO>();
    while (!events.isEmpty() && sorted.size() < size) {
      Integer best = 0;
      for (Integer i = 1; i < events.size(); i++) {
        Datetime a = events[i].eventAt;
        Datetime b = events[best].eventAt;
        if (a != null && (b == null || a > b))
          best = i;
      }
      sorted.add(events.remove(best));
    }
    return sorted;
  }

  @TestVisible
  static EventDTO baseApptEvent(
    Appointment__c a,
    String type,
    Datetime whenDt,
    String actorName,
    String detail
  ) {
    EventDTO d = new EventDTO();
    d.id = a.Id;
    d.eventType = type;
    d.outcome = type;
    d.detail = detail;
    d.summary = type +
      (a.Start_Date_Time__c == null
        ? ''
        : ' — ' + String.valueOf(a.Start_Date_Time__c));
    d.careItemKey = 'APPOINTMENT';
    d.careItemLabel = String.isBlank(a.Name) ? 'Appointment' : a.Name;
    d.eventAt = whenDt == null ? a.CreatedDate : whenDt;
    d.actorName = actorName;
    d.sourceKind = 'appointment';
    return d;
  }

  @TestVisible
  static void enrichEventPlainLanguage(
    EventDTO d,
    Map<String, Outreach_Rule__mdt> rulesById
  ) {
    if (d == null)
      return;
    Outreach_Rule__mdt rule = String.isBlank(d.ruleId) || rulesById == null
      ? null
      : rulesById.get(d.ruleId);
    String label = rule != null && String.isNotBlank(rule.Display_Label__c)
      ? rule.Display_Label__c
      : (String.isBlank(d.ruleId) ? null : friendlyNeedLabel(d.ruleId));
    d.careItemKey = careItemParentKey(
      d.ruleId,
      rule == null ? null : rule.Need_Type__c,
      rule == null ? null : rule.Family__c
    );
    if (String.isBlank(d.careItemKey)) {
      d.careItemKey = 'ACTIVITY';
      d.careItemLabel = 'Outreach activity';
    } else {
      d.careItemLabel = careItemParentLabel(d.careItemKey, label);
    }
    String type = d.eventType == null ? '' : d.eventType;
    if (type == 'Need Opened' || type == 'Care Item Opened') {
      d.summary = d.careItemLabel + ' became active';
      if (String.isNotBlank(label) && label != d.careItemLabel)
        d.summary += ' (' + label + ')';
      d.eventType = 'Care Item Opened';
    } else if (type == 'Need Closed' || type == 'Care Item Closed') {
      d.summary = d.careItemLabel + ' was closed';
      d.eventType = 'Care Item Closed';
    } else if (type == 'Reviewed Outreach') {
      if (d.outcome == 'Soft Hold')
        d.summary = 'Soft hold recorded (reviewed outreach)';
      else
        d.summary = String.isNotBlank(d.detail)
          ? d.detail
          : 'Outreach reviewed';
    } else if (String.isNotBlank(d.outcome)) {
      d.summary = type + (String.isBlank(d.outcome) ? '' : ' — ' + d.outcome);
    } else if (String.isNotBlank(d.detail)) {
      d.summary = d.detail;
    } else {
      d.summary = type;
    }
  }

  @TestVisible
  static String careItemParentKey(
    String ruleId,
    String needType,
    String family
  ) {
    return OutreachCareItemTaxonomy.parentKey(ruleId, needType, family);
  }

  @TestVisible
  static String careItemParentLabel(String key, String fallback) {
    return OutreachCareItemTaxonomy.parentLabel(key, fallback);
  }

  @AuraEnabled
  public static RowDTO recordSoftHold(Id recordId) {
    RowDTO workspace = getPatientWorkspace(recordId);
    if (workspace == null || workspace.episodeId == null)
      return workspace;
    // Soft hold: log review event only — no claim / ownership transfer.
    List<OutreachEventService.EventRequest> events = new List<OutreachEventService.EventRequest>();
    OutreachEventService.EventRequest r = new OutreachEventService.EventRequest();
    r.patientId = workspace.patientId;
    r.episodeId = workspace.episodeId;
    r.eventType = 'Reviewed Outreach';
    r.outcome = 'Soft Hold';
    r.detail = UserInfo.getName() + ' reviewed outreach';
    // Once per agent per patient per calendar day.
    r.idempotencyKey =
      String.valueOf(workspace.patientId) +
      ':Reviewed:' +
      String.valueOf(UserInfo.getUserId()) +
      ':' +
      String.valueOf(Date.today());
    events.add(r);
    OutreachEventService.append(events);
    // Soft-hold is idempotent per agent/day; avoid a second workspace hydrate.
    return workspace;
  }

  @AuraEnabled
  public static RowDTO silenceNeed(
    Id patientId,
    Id needId,
    String reason,
    Date expiry
  ) {
    if (patientId == null || needId == null)
      throw new AuraHandledException('Patient and need are required.');
    if (String.isBlank(reason))
      throw new AuraHandledException(
        'A reason is required to silence this care item (opt the patient out of future reminders).'
      );
    String silenceReason = reason.trim();
    Patient_Need__c need = [
      SELECT
        Id,
        Engine_Key__c,
        Patient__c,
        Episode__c,
        Rule_Id__c,
        Need_Type__c,
        Shadow__c,
        State__c
      FROM Patient_Need__c
      WHERE Id = :needId AND Patient__c = :patientId
      WITH USER_MODE
      LIMIT 1
    ];
    Suppression__c s = new Suppression__c(
      Engine_Key__c = patientId + ':' + need.Need_Type__c + ':Silence',
      Patient__c = patientId,
      Need_Type__c = need.Need_Type__c,
      Channel__c = 'All',
      Reason__c = silenceReason,
      Source__c = 'Workbench',
      Active__c = true,
      Effective_Start__c = Date.today(),
      Expires_On__c = expiry
    );
    upsert as user s Suppression__c.Engine_Key__c;
    need.State__c = 'Silenced';
    need.Resolution_Reason__c = silenceReason;
    update as user need;
    // DEV-4684: silence with communication topic → async OptOut Email+SMS consents
    try {
      List<Outreach_Rule__mdt> rules = [
        SELECT Communication_Topic__c
        FROM Outreach_Rule__mdt
        WHERE Rule_Id__c = :need.Rule_Id__c
        LIMIT 1
      ];
      if (!rules.isEmpty() && !String.isBlank(rules[0].Communication_Topic__c)) {
        // Skip enqueue in existing high-SOQL workbench tests unless explicitly forced.
        if (!Test.isRunningTest() || forceSilenceConsentEnqueue) {
          System.enqueueJob(
            new OutreachSilenceConsentQueueable(
              patientId,
              rules[0].Communication_Topic__c
            )
          );
        }
      }
    } catch (Exception silenceConsentEx) {
      System.debug(
        LoggingLevel.WARN,
        'silenceNeed consent opt-out skipped: ' + silenceConsentEx.getMessage()
      );
    }
    OutreachEventService.EventRequest r = new OutreachEventService.EventRequest();
    r.patientId = patientId;
    r.episodeId = need.Episode__c;
    r.needId = need.Id;
    r.ruleId = need.Rule_Id__c;
    r.eventType = 'Silenced';
    r.detail = silenceReason;
    r.shadow = need.Shadow__c;
    r.idempotencyKey = need.Engine_Key__c + ':Silenced:' + s.Engine_Key__c;
    OutreachEventService.append(
      new List<OutreachEventService.EventRequest>{ r }
    );
    OutreachEpisodePlanner.plan(new Set<Id>{ patientId });
    return getPatientWorkspace(patientId);
  }

  @AuraEnabled
  public static RowDTO unsilenceNeed(Id patientId, Id needId) {
    if (patientId == null || needId == null)
      throw new AuraHandledException('Patient and need are required.');
    Patient_Need__c need = [
      SELECT
        Id,
        Engine_Key__c,
        Patient__c,
        Episode__c,
        Rule_Id__c,
        Need_Type__c,
        Shadow__c,
        State__c
      FROM Patient_Need__c
      WHERE Id = :needId AND Patient__c = :patientId
      WITH USER_MODE
      LIMIT 1
    ];
    need.State__c = 'Pending';
    need.Resolution_Reason__c = null;
    update as user need;
    List<Suppression__c> suppressions = [
      SELECT Id, Active__c, Engine_Key__c
      FROM Suppression__c
      WHERE
        Patient__c = :patientId
        AND Need_Type__c = :need.Need_Type__c
        AND Active__c = TRUE
      WITH USER_MODE
    ];
    for (Suppression__c s : suppressions)
      s.Active__c = false;
    if (!suppressions.isEmpty())
      update as user suppressions;
    OutreachEventService.EventRequest r = new OutreachEventService.EventRequest();
    r.patientId = patientId;
    r.episodeId = need.Episode__c;
    r.needId = need.Id;
    r.ruleId = need.Rule_Id__c;
    r.eventType = 'Unsilenced';
    r.detail = 'Manually unsilenced';
    r.shadow = need.Shadow__c;
    r.idempotencyKey =
      need.Engine_Key__c +
      ':Unsilenced:' +
      String.valueOf(Datetime.now().getTime());
    OutreachEventService.append(
      new List<OutreachEventService.EventRequest>{ r }
    );
    OutreachEpisodePlanner.plan(new Set<Id>{ patientId });
    return getPatientWorkspace(patientId);
  }

  @AuraEnabled
  public static RowDTO wakeNeed(Id patientId, Id needId) {
    if (patientId == null || needId == null)
      throw new AuraHandledException('Patient and care item are required.');
    Patient_Need__c need = [
      SELECT
        Id,
        Patient__c,
        Episode__c,
        Engine_Key__c,
        Rule_Id__c,
        State__c,
        Shadow__c
      FROM Patient_Need__c
      WHERE Id = :needId AND Patient__c = :patientId
      WITH USER_MODE
      FOR UPDATE
    ];
    if (need.State__c != 'Snoozed')
      throw new AuraHandledException('Only snoozed care items can be woken.');
    need.State__c = 'Pending';
    need.Snooze_Until__c = null;
    update as user need;
    OutreachEventService.EventRequest r = new OutreachEventService.EventRequest();
    r.patientId = need.Patient__c;
    r.episodeId = need.Episode__c;
    r.needId = need.Id;
    r.ruleId = need.Rule_Id__c;
    r.eventType = 'Care Item Opened';
    r.detail = 'Care item woken from snooze';
    r.shadow = need.Shadow__c;
    r.idempotencyKey =
      need.Engine_Key__c +
      ':Woke:' +
      String.valueOf(Datetime.now().getTime());
    OutreachEventService.append(
      new List<OutreachEventService.EventRequest>{ r }
    );
    OutreachEpisodePlanner.plan(new Set<Id>{ patientId });
    return getPatientWorkspace(patientId);
  }

  @AuraEnabled
  public static RowDTO extendNeedSnooze(
    Id patientId,
    Id needId,
    Date snoozeUntil
  ) {
    if (patientId == null || needId == null)
      throw new AuraHandledException('Patient and care item are required.');
    if (snoozeUntil == null)
      throw new AuraHandledException('Pick a snooze override date.');
    Date minDate = Date.today().addDays(1);
    Date maxDate = Date.today().addDays(365);
    if (snoozeUntil < minDate)
      throw new AuraHandledException(
        'Override date must be at least tomorrow.'
      );
    if (snoozeUntil > maxDate)
      throw new AuraHandledException(
        'Override date cannot be more than 365 days in the future.'
      );
    Patient_Need__c need = [
      SELECT
        Id,
        Patient__c,
        Episode__c,
        Engine_Key__c,
        Rule_Id__c,
        State__c,
        Shadow__c
      FROM Patient_Need__c
      WHERE Id = :needId AND Patient__c = :patientId
      WITH USER_MODE
      FOR UPDATE
    ];
    if (need.State__c != 'Snoozed')
      throw new AuraHandledException(
        'Only snoozed care items can be extended.'
      );
    Datetime untilDt = Datetime.newInstance(
      snoozeUntil,
      Time.newInstance(0, 0, 0, 0)
    );
    need.Snooze_Until__c = untilDt;
    update as user need;
    OutreachEventService.EventRequest r = new OutreachEventService.EventRequest();
    r.patientId = need.Patient__c;
    r.episodeId = need.Episode__c;
    r.needId = need.Id;
    r.ruleId = need.Rule_Id__c;
    r.eventType = 'Snoozed';
    r.outcome = 'Snoozed';
    r.detail = 'Snooze overridden until ' + String.valueOf(snoozeUntil);
    r.shadow = need.Shadow__c;
    r.idempotencyKey =
      need.Engine_Key__c +
      ':ExtendSnooze:' +
      String.valueOf(Datetime.now().getTime());
    OutreachEventService.append(
      new List<OutreachEventService.EventRequest>{ r }
    );
    OutreachEpisodePlanner.plan(new Set<Id>{ patientId });
    return getPatientWorkspace(patientId);
  }

  @AuraEnabled
  public static RowDTO logOutcome(
    Id episodeId,
    String outcome,
    String channel,
    String detail,
    Date snoozeUntil,
    Boolean closeRelated,
    List<Id> selectedNeedIds,
    List<Id> acknowledgedNeedIds,
    String caseStatus,
    String disposition,
    String inactiveReason,
    Boolean commentOnly,
    Boolean keepWorking
  ) {
    Outreach_Episode__c episode = [
      SELECT
        Id,
        Patient__c,
        Status__c,
        OwnerId,
        Legacy_Primary_Case__c,
        Soft_Held_By__c,
        Soft_Hold_Until__c,
        Claimed_At__c
      FROM Outreach_Episode__c
      WHERE Id = :episodeId
      WITH USER_MODE
      FOR UPDATE
    ];

    // Outcome is first-class; disposition kept only as a legacy alias.
    String effectiveOutcome = String.isNotBlank(outcome)
      ? outcome
      : dispositionToOutcome(disposition);
    if (String.isBlank(effectiveOutcome))
      effectiveOutcome = 'Left Message';

    Boolean isCommentOnly = commentOnly == true;
    if (
      !isCommentOnly && isDailyAttemptLocked(episode.Patient__c, episode.Id)
    ) {
      // Enforce daily attempt limit unless a need on this episode overrides.
      isCommentOnly = true;
    }

    if (isCommentOnly) {
      if (String.isBlank(detail))
        throw new AuraHandledException('Comment Only mode requires a comment.');
      OutreachEventService.EventRequest r = new OutreachEventService.EventRequest();
      r.patientId = episode.Patient__c;
      r.episodeId = episode.Id;
      r.eventType = 'Comment';
      r.outcome = 'Comment Only';
      r.channel = channel;
      r.detail = detail;
      r.idempotencyKey =
        String.valueOf(episode.Id) +
        ':Comment:' +
        String.valueOf(Datetime.now().getTime());
      OutreachEventService.append(
        new List<OutreachEventService.EventRequest>{ r }
      );
      return getPatientWorkspace(episode.Patient__c);
    }

    if (
      effectiveOutcome == 'Inactive Patient' && String.isBlank(inactiveReason)
    ) {
      throw new AuraHandledException(
        'Inactive Reason is required when outcome is Inactive Patient.'
      );
    }

    Boolean selectedProvided = selectedNeedIds != null;
    Set<Id> selected = selectedProvided
      ? new Set<Id>(selectedNeedIds)
      : new Set<Id>();
    Set<Id> acknowledged = acknowledgedNeedIds == null
      ? new Set<Id>()
      : new Set<Id>(acknowledgedNeedIds);

    List<Patient_Need__c> needs = [
      SELECT
        Id,
        Engine_Key__c,
        Patient__c,
        Episode__c,
        Rule_Id__c,
        Need_Type__c,
        State__c,
        Attempt_Count__c,
        Next_Action_Date__c,
        Snooze_Until__c,
        Resolution_Reason__c,
        Shadow__c
      FROM Patient_Need__c
      WHERE
        Episode__c = :episodeId
        AND State__c IN ('Pending', 'In Progress', 'Snoozed')
      WITH USER_MODE
    ];
    if (selected.isEmpty()) {
      // Explicit empty selection on Snooze must not silently snooze every care item.
      if (selectedProvided && effectiveOutcome == 'Snoozed') {
        throw new AuraHandledException(
          'Select at least one care item to snooze.'
        );
      }
      for (Patient_Need__c n : needs)
        selected.add(n.Id);
    }
    if (effectiveOutcome == 'Snoozed' && snoozeUntil == null) {
      throw new AuraHandledException('Snooze until date is required.');
    }

    Map<String, Boolean> forceByRule = new Map<String, Boolean>();
    for (Outreach_Rule__mdt rule : [
      SELECT Rule_Id__c, Force_Acknowledge__c
      FROM Outreach_Rule__mdt
      WHERE Force_Acknowledge__c = TRUE
    ])
      forceByRule.put(rule.Rule_Id__c, true);
    Map<String, Cadence_Policy__mdt> cadenceByRule = cadencePoliciesByRule(
      needs
    );

    for (Patient_Need__c n : needs) {
      if (!selected.contains(n.Id))
        continue;
      if (
        forceByRule.containsKey(n.Rule_Id__c) && !acknowledged.contains(n.Id)
      ) {
        throw new AuraHandledException(
          'Confirm that "' +
            n.Need_Type__c +
            '" was addressed before logging the outcome.'
        );
      }
    }

    Boolean shouldClose =
      isClosedDisposition(effectiveOutcome) || isClosedDisposition(disposition);

    String eventType = eventType(effectiveOutcome);
    List<OutreachEventService.EventRequest> events = new List<OutreachEventService.EventRequest>();
    Datetime snooze = snoozeUntil == null
      ? null
      : Datetime.newInstance(snoozeUntil, Time.newInstance(0, 0, 0, 0));
    List<Patient_Need__c> toUpdate = new List<Patient_Need__c>();
    List<Suppression__c> pendingSuppressions = new List<Suppression__c>();
    // Phase 1: all RulesEngine callouts before any DML (multi-need outcomes).
    Set<String> selectedRuleIds = new Set<String>();
    for (Patient_Need__c n : needs) {
      if (selected.contains(n.Id) && String.isNotBlank(n.Rule_Id__c))
        selectedRuleIds.add(n.Rule_Id__c);
    }
    Map<String, String> families = familyByRuleId(selectedRuleIds);
    Map<Id, OutreachRulesEngineClient.ReactionResult> reactions = new Map<Id, OutreachRulesEngineClient.ReactionResult>();
    for (Patient_Need__c n : needs) {
      if (!selected.contains(n.Id))
        continue;
      Integer attempt = n.Attempt_Count__c == null
        ? 1
        : n.Attempt_Count__c.intValue() + 1;
      n.Attempt_Count__c = attempt;
      reactions.put(
        n.Id,
        evaluateRulesEngineReaction(
          n,
          cadenceByRule.get(n.Rule_Id__c),
          effectiveOutcome,
          families.get(n.Rule_Id__c)
        )
      );
    }
    // Phase 2: apply reaction results in memory (no callouts / no DML).
    for (Patient_Need__c n : needs) {
      if (!selected.contains(n.Id))
        continue;
      Integer attempt = n.Attempt_Count__c == null
        ? 0
        : n.Attempt_Count__c.intValue();
      if (shouldClose) {
        n.State__c = 'Resolved';
        n.Resolution_Reason__c = String.isNotBlank(disposition)
          ? disposition
          : effectiveOutcome;
        n.Snooze_Until__c = null;
        n.Next_Action_Date__c = null;
      }
      applyRulesEngineReaction(
        n,
        cadenceByRule.get(n.Rule_Id__c),
        reactions.get(n.Id),
        pendingSuppressions
      );
      if (
        !shouldClose &&
        n.State__c != 'Resolved' &&
        (eventType == 'Snoozed' || caseStatus == 'On Hold') &&
        snooze != null
      ) {
        n.State__c = 'Snoozed';
        n.Snooze_Until__c = snooze;
        n.Next_Action_Date__c = snooze.date();
      }
      toUpdate.add(n);
      OutreachEventService.EventRequest r = new OutreachEventService.EventRequest();
      r.patientId = n.Patient__c;
      r.episodeId = n.Episode__c;
      r.needId = n.Id;
      r.ruleId = n.Rule_Id__c;
      r.eventType = eventType;
      r.outcome = effectiveOutcome;
      r.channel = channel;
      r.detail = detail;
      if (
        effectiveOutcome == 'Inactive Patient' &&
        String.isNotBlank(inactiveReason)
      ) {
        r.detail = String.isBlank(detail)
          ? 'Inactive reason: ' + inactiveReason
          : 'Inactive reason: ' + inactiveReason + '\n' + detail;
      }
      r.attemptNumber = attempt;
      r.shadow = n.Shadow__c;
      r.idempotencyKey =
        n.Engine_Key__c +
        ':' +
        eventType +
        ':' +
        String.valueOf(Datetime.now().getTime());
      events.add(r);
    }

    flushSuppressions(pendingSuppressions);

    Boolean touchedAllActive = true;
    for (Patient_Need__c n : needs) {
      if (!selected.contains(n.Id)) {
        touchedAllActive = false;
        break;
      }
    }
    Boolean stayWorking = keepWorking == true;
    Id queueId = pesOutreachQueueId();
    if (eventType == 'Snoozed' || caseStatus == 'On Hold') {
      episode.Status__c = touchedAllActive ? 'Snoozed' : 'Unclaimed';
      if (touchedAllActive && snooze != null)
        episode.Next_Action_Date__c = snooze.date();
    } else if (shouldClose) {
      episode.Status__c = touchedAllActive ? 'Completed' : 'Unclaimed';
    } else {
      episode.Status__c = 'Unclaimed';
    }
    if (stayWorking) {
      episode.Soft_Held_By__c = UserInfo.getUserId();
      episode.Soft_Hold_Until__c = System.now()
        .addMinutes(SOFT_HOLD_TTL_MINUTES);
    } else {
      clearSoftHold(episode);
      if (queueId != null)
        episode.OwnerId = queueId;
      episode.Claimed_At__c = null;
    }
    update as user episode;

    if (!toUpdate.isEmpty()) {
      List<Patient_Need__c> safeNeeds = (List<Patient_Need__c>) Security.stripInaccessible(
          AccessType.UPDATABLE,
          toUpdate
        )
        .getRecords();
      update as user safeNeeds;
    }
    OutreachEventService.append(events);
    Account patientStatusUpdate = accountStatusUpdateForOutcome(
      episode.Patient__c,
      effectiveOutcome,
      inactiveReason,
      System.now()
    );
    if (patientStatusUpdate != null)
      update as user patientStatusUpdate;

    OutreachEpisodePlanner.plan(new Set<Id>{ episode.Patient__c });
    return getPatientWorkspace(episode.Patient__c);
  }

  @TestVisible
  static String dispositionToOutcome(String disposition) {
    if (String.isBlank(disposition))
      return null;
    if (disposition == 'Patient Scheduled')
      return 'Appointment Scheduled';
    if (disposition == 'Left Message')
      return 'Left Message';
    if (disposition == 'Unable to Reach')
      return 'Unable to Reach';
    if (disposition == 'Inactive Patient')
      return 'Inactive Patient';
    if (disposition == 'Patient Deceased')
      return 'Patient Deceased';
    if (disposition == 'Patient Refused Scheduling')
      return 'Patient Refused Scheduling';
    if (disposition == 'Did not respond')
      return 'Did not respond';
    if (disposition == 'Escalated for Service Recovery')
      return 'Handoff To Marketing';
    if (disposition == 'Needs Call Back')
      return 'Connected';
    if (disposition == 'Awaiting Patient Callback')
      return 'Snoozed';
    if (disposition == 'Awaiting Patient Response')
      return 'Snoozed';
    return disposition;
  }

  @TestVisible
  static Boolean isClosedDisposition(String disposition) {
    return new Set<String>{
        'Appointment Scheduled',
        'Inactive Patient',
        'Patient Deceased',
        'Patient Refused Scheduling',
        'Patient Refused',
        'Patient Scheduled'
      }
      .contains(disposition);
  }

  @TestVisible
  static Boolean isRefusedOutcome(String outcome) {
    return new Set<String>{
        'Patient Refused Scheduling',
        'Patient Refused'
      }
      .contains(outcome);
  }

  @TestVisible
  static Account accountStatusUpdateForOutcome(
    Id patientId,
    String outcome,
    String inactiveReason,
    Datetime occurredAt
  ) {
    if (patientId == null)
      return null;
    if (outcome == 'Inactive Patient') {
      return new Account(
        Id = patientId,
        HealthCloudGA__Active__c = 'i',
        Inactive_Reasons__c = inactiveReason
      );
    }
    if (outcome == 'Patient Deceased') {
      return new Account(
        Id = patientId,
        PersonDeceasedDate = occurredAt == null ? System.now() : occurredAt
      );
    }
    return null;
  }

  @AuraEnabled
  public static RowDTO suppressNeed(
    Id patientId,
    String needType,
    String reason,
    Date expiry
  ) {
    if (patientId == null || String.isBlank(needType))
      throw new AuraHandledException('Patient and need type are required.');
    if (String.isBlank(reason))
      throw new AuraHandledException('Suppression reason is required.');
    if (expiry != null && expiry < Date.today())
      throw new AuraHandledException(
        'Suppression expiry cannot be in the past.'
      );
    Suppression__c s = new Suppression__c(
      Engine_Key__c = patientId + ':' + needType + ':All',
      Patient__c = patientId,
      Need_Type__c = needType,
      Channel__c = 'All',
      Reason__c = reason,
      Source__c = 'Workbench',
      Active__c = true,
      Effective_Start__c = Date.today(),
      Expires_On__c = expiry
    );
    List<Suppression__c> safeSuppressions = (List<Suppression__c>) Security.stripInaccessible(
        AccessType.CREATABLE,
        new List<Suppression__c>{ s }
      )
      .getRecords();
    upsert as user safeSuppressions Suppression__c.Engine_Key__c;
    List<Patient_Need__c> needs = [
      SELECT
        Id,
        Engine_Key__c,
        Patient__c,
        Episode__c,
        Rule_Id__c,
        Shadow__c,
        Need_Type__c,
        State__c
      FROM Patient_Need__c
      WHERE
        Patient__c = :patientId
        AND Need_Type__c = :needType
        AND State__c IN ('Pending', 'In Progress', 'Snoozed')
      WITH USER_MODE
    ];
    List<OutreachEventService.EventRequest> events = new List<OutreachEventService.EventRequest>();
    for (Patient_Need__c n : needs) {
      n.State__c = 'Suppressed';
      n.Resolution_Reason__c = reason;
      OutreachEventService.EventRequest r = new OutreachEventService.EventRequest();
      r.patientId = patientId;
      r.episodeId = n.Episode__c;
      r.needId = n.Id;
      r.ruleId = n.Rule_Id__c;
      r.eventType = 'Suppressed';
      r.detail = reason;
      r.idempotencyKey = n.Engine_Key__c + ':Suppressed:' + s.Engine_Key__c;
      r.shadow = n.Shadow__c;
      events.add(r);
    }
    if (!needs.isEmpty())
      update as user needs;
    OutreachEventService.append(events);
    OutreachEpisodePlanner.plan(new Set<Id>{ patientId });
    return getPatientWorkspace(patientId);
  }

  @AuraEnabled
  public static List<RowDTO> evaluatePatients(List<Id> patientIds) {
    Set<Id> ids = new Set<Id>(patientIds);
    OutreachRuleEvaluator.evaluate(ids);
    OutreachEpisodePlanner.plan(ids);
    return getRows(Math.min(ids.size(), 200), null, 'All');
  }

  @TestVisible
  private static Boolean claimCandidate(Id candidateId) {
    List<Outreach_Episode__c> locked = [
      SELECT
        Id,
        Patient__c,
        Status__c,
        OwnerId,
        Soft_Held_By__c,
        Soft_Hold_Until__c
      FROM Outreach_Episode__c
      WHERE Id = :candidateId
      WITH USER_MODE
      FOR UPDATE
    ];
    if (locked.isEmpty())
      return false;
    Outreach_Episode__c e = locked[0];
    if (e.Status__c == 'Completed' || e.Status__c == 'Cancelled')
      return false;
    if (
      e.Soft_Held_By__c != null &&
      e.Soft_Held_By__c != UserInfo.getUserId() &&
      e.Soft_Hold_Until__c != null &&
      e.Soft_Hold_Until__c > System.now()
    )
      return false;
    claimLocked(e, UserInfo.getUserId());
    return true;
  }
  private static void claimLocked(Outreach_Episode__c e, Id userId) {
    e.Soft_Held_By__c = userId;
    e.Soft_Hold_Until__c = System.now().addMinutes(SOFT_HOLD_TTL_MINUTES);
    if (String.isBlank(e.Status__c) || e.Status__c == 'Claimed')
      e.Status__c = 'Unclaimed';
    update as user e;
    OutreachEventService.EventRequest r = new OutreachEventService.EventRequest();
    r.patientId = e.Patient__c;
    r.episodeId = e.Id;
    r.eventType = 'Reviewed Outreach';
    r.outcome = 'Soft Hold';
    r.detail = UserInfo.getName() + ' opened outreach (soft claim)';
    r.idempotencyKey =
      e.Id + ':SoftHold:' + userId + ':' + String.valueOf(System.now().getTime());
    OutreachEventService.append(
      new List<OutreachEventService.EventRequest>{ r }
    );
  }
  private static final Integer SOFT_HOLD_TTL_MINUTES = 30;

  private static Id pesOutreachQueueId() {
    List<Group> rows = [
      SELECT Id
      FROM Group
      WHERE Type = 'Queue' AND DeveloperName = 'PES_Outreach'
      WITH USER_MODE
      LIMIT 1
    ];
    return rows.isEmpty() ? null : rows[0].Id;
  }

  @TestVisible
  static void clearSoftHold(Outreach_Episode__c e) {
    if (e == null)
      return;
    e.Soft_Held_By__c = null;
    e.Soft_Hold_Until__c = null;
  }

  private static String eventType(String outcome) {
    return OutreachOutcomeCatalog.eventTypeForOutcome(outcome);
  }
  @TestVisible
  static void applyAttemptCadence(
    Patient_Need__c need,
    Cadence_Policy__mdt policy
  ) {
    applyAttemptCadence(need, policy, null);
  }

  @TestVisible
  static void applyAttemptCadence(
    Patient_Need__c need,
    Cadence_Policy__mdt policy,
    String outcome
  ) {
    String family = need == null ? null : need.Need_Type__c;
    if (need != null && String.isNotBlank(need.Rule_Id__c)) {
      Map<String, String> families = familyByRuleId(
        new Set<String>{ need.Rule_Id__c }
      );
      if (families.containsKey(need.Rule_Id__c))
        family = families.get(need.Rule_Id__c);
    }
    OutreachRulesEngineClient.ReactionResult rx = evaluateRulesEngineReaction(
      need,
      policy,
      outcome,
      family
    );
    List<Suppression__c> pending = new List<Suppression__c>();
    applyRulesEngineReaction(need, policy, rx, pending);
    flushSuppressions(pending);
  }

  @TestVisible
  static OutreachRulesEngineClient.ReactionResult evaluateRulesEngineReaction(
    Patient_Need__c need,
    Cadence_Policy__mdt policy,
    String outcome
  ) {
    return evaluateRulesEngineReaction(need, policy, outcome, null);
  }

  @TestVisible
  static OutreachRulesEngineClient.ReactionResult evaluateRulesEngineReaction(
    Patient_Need__c need,
    Cadence_Policy__mdt policy,
    String outcome,
    String familyOverride
  ) {
    if (!OutreachRulesEngineClient.isEnabled()) {
      throw new AuraHandledException(
        'RulesEngine reaction is required (Outreach_RulesEngine_Settings.Default.Enabled__c).'
      );
    }
    Integer maxAttempts = policy == null ||
      policy.Max_Attempts__c == null
      ? 2
      : policy.Max_Attempts__c.intValue();
    Integer intervalDays = policy == null ||
      policy.Attempt_Interval_Days__c == null
      ? 7
      : policy.Attempt_Interval_Days__c.intValue();
    Integer attempts = need.Attempt_Count__c == null
      ? 0
      : need.Attempt_Count__c.intValue();

    String family = String.isNotBlank(familyOverride)
      ? familyOverride
      : need.Need_Type__c;
    Map<String, Object> ctx = new Map<String, Object>{
      'outcome' => outcome,
      'family' => family,
      'ruleId' => need.Rule_Id__c,
      'attemptCount' => attempts,
      'maxAttempts' => maxAttempts,
      'defaultIntervalDays' => intervalDays
    };
    OutreachRulesEngineClient.ReactionResult rx = OutreachRulesEngineClient.evaluateReaction(
      ctx
    );
    if (rx == null) {
      throw new AuraHandledException(
        'RulesEngine reaction returned no result for outcome handling.'
      );
    }
    return rx;
  }

  @TestVisible
  static Map<String, String> familyByRuleId(Set<String> ruleIds) {
    Map<String, String> out = new Map<String, String>();
    if (ruleIds == null || ruleIds.isEmpty())
      return out;
    for (Outreach_Rule__mdt rule : [
      SELECT Rule_Id__c, Family__c
      FROM Outreach_Rule__mdt
      WHERE Rule_Id__c IN :ruleIds
    ]) {
      if (String.isNotBlank(rule.Rule_Id__c) && String.isNotBlank(rule.Family__c))
        out.put(rule.Rule_Id__c, rule.Family__c);
    }
    return out;
  }

  @TestVisible
  static void applyRulesEngineReaction(
    Patient_Need__c need,
    Cadence_Policy__mdt policy,
    OutreachRulesEngineClient.ReactionResult rx,
    List<Suppression__c> pendingSuppressions
  ) {
    if (need == null || rx == null)
      return;
    Integer intervalDays = policy == null ||
      policy.Attempt_Interval_Days__c == null
      ? 7
      : policy.Attempt_Interval_Days__c.intValue();
    if (rx.resolve == true) {
      need.State__c = 'Resolved';
      need.Resolution_Reason__c = String.isNotBlank(rx.reason)
        ? rx.reason
        : 'Max attempts reached';
      queueSuppression(
        pendingSuppressions,
        need.Patient__c,
        need.Need_Type__c,
        rx.suppressDays,
        rx.reason
      );
      if (rx.snoozeDays != null && rx.snoozeDays > 0) {
        Date nextDate = Date.today().addDays(rx.snoozeDays);
        need.Snooze_Until__c = Datetime.newInstance(
          nextDate,
          Time.newInstance(0, 0, 0, 0)
        );
        need.Next_Action_Date__c = nextDate;
      } else {
        need.Snooze_Until__c = null;
        need.Next_Action_Date__c = null;
      }
      return;
    }
    Integer snoozeDays = rx.snoozeDays != null && rx.snoozeDays > 0
      ? rx.snoozeDays
      : Math.max(1, intervalDays);
    Date nextDate = Date.today().addDays(snoozeDays);
    need.State__c = 'Snoozed';
    need.Resolution_Reason__c = null;
    need.Next_Action_Date__c = nextDate;
    need.Snooze_Until__c = Datetime.newInstance(
      nextDate,
      Time.newInstance(0, 0, 0, 0)
    );
    queueSuppression(
      pendingSuppressions,
      need.Patient__c,
      need.Need_Type__c,
      rx.suppressDays,
      rx.reason
    );
  }

  @TestVisible
  static void queueSuppression(
    List<Suppression__c> pending,
    Id patientId,
    String needType,
    Integer days,
    String reason
  ) {
    if (
      pending == null ||
      patientId == null ||
      String.isBlank(needType) ||
      days == null ||
      days <= 0
    )
      return;
    Date expiry = Date.today().addDays(days);
    pending.add(
      new Suppression__c(
        Engine_Key__c = patientId + ':' + needType + ':RulesEngine',
        Patient__c = patientId,
        Need_Type__c = needType,
        Channel__c = 'All',
        Active__c = true,
        Source__c = 'RulesEngine',
        Reason__c = String.isBlank(reason) ? 'RulesEngine reaction' : reason,
        Effective_Start__c = Date.today(),
        Expires_On__c = expiry
      )
    );
  }

  @TestVisible
  static void flushSuppressions(List<Suppression__c> pending) {
    if (pending == null || pending.isEmpty())
      return;
    upsert as user pending Suppression__c.Engine_Key__c;
  }

  @TestVisible
  static void upsertSuppression(
    Id patientId,
    String needType,
    Integer days,
    String reason
  ) {
    if (patientId == null || String.isBlank(needType) || days == null || days <= 0)
      return;
    Date expiry = Date.today().addDays(days);
    Suppression__c row = new Suppression__c(
      Engine_Key__c = patientId + ':' + needType + ':RulesEngine',
      Patient__c = patientId,
      Need_Type__c = needType,
      Channel__c = 'All',
      Active__c = true,
      Source__c = 'RulesEngine',
      Reason__c = String.isBlank(reason) ? 'RulesEngine reaction' : reason,
      Effective_Start__c = Date.today(),
      Expires_On__c = expiry
    );
    upsert as user row Suppression__c.Engine_Key__c;
  }

  private static Map<String, Cadence_Policy__mdt> cadencePoliciesByRule(
    List<Patient_Need__c> needs
  ) {
    Set<String> ruleIds = new Set<String>();
    for (Patient_Need__c need : needs)
      if (String.isNotBlank(need.Rule_Id__c))
        ruleIds.add(need.Rule_Id__c);
    Map<String, String> policyNameByRule = new Map<String, String>();
    Set<String> policyNames = new Set<String>();
    if (!ruleIds.isEmpty()) {
      for (Outreach_Rule__mdt rule : [
        SELECT Rule_Id__c, Cadence_Policy__c
        FROM Outreach_Rule__mdt
        WHERE Rule_Id__c IN :ruleIds
      ]) {
        if (String.isBlank(rule.Cadence_Policy__c))
          continue;
        policyNameByRule.put(rule.Rule_Id__c, rule.Cadence_Policy__c);
        policyNames.add(rule.Cadence_Policy__c);
      }
    }
    Map<String, Cadence_Policy__mdt> policyByName = new Map<String, Cadence_Policy__mdt>();
    if (!policyNames.isEmpty()) {
      for (Cadence_Policy__mdt policy : [
        SELECT DeveloperName, Attempt_Interval_Days__c, Max_Attempts__c
        FROM Cadence_Policy__mdt
        WHERE DeveloperName IN :policyNames
      ])
        policyByName.put(policy.DeveloperName, policy);
    }
    Map<String, Cadence_Policy__mdt> result = new Map<String, Cadence_Policy__mdt>();
    for (String ruleId : policyNameByRule.keySet())
      result.put(ruleId, policyByName.get(policyNameByRule.get(ruleId)));
    return result;
  }

  private static List<RowDTO> toRows(List<Outreach_Episode__c> episodes) {
    Set<Id> ids = new Set<Id>();
    for (Outreach_Episode__c e : episodes)
      ids.add(e.Id);
    Map<Id, List<NeedDTO>> needs = new Map<Id, List<NeedDTO>>();
    for (Id id : ids)
      needs.put(id, new List<NeedDTO>());
    for (Patient_Need__c n : [
      SELECT
        Id,
        Episode__c,
        Need_Type__c,
        Rule_Id__c,
        State__c,
        Priority__c,
        Points__c,
        Attempt_Count__c,
        Next_Action_Date__c,
        Snooze_Until__c,
        Schedule_Bound_Type__c,
        Schedule_Earliest__c,
        Schedule_Latest__c,
        Schedule_Phrase__c,
        Schedule_Status_Label__c
      FROM Patient_Need__c
      WHERE
        Episode__c IN :ids
        AND State__c IN (
          'Pending',
          'In Progress',
          'Snoozed',
          'Resolved',
          'Superseded',
          'Shadow',
          'Silenced'
        )
      WITH USER_MODE
    ]) {
      NeedDTO d = new NeedDTO();
      d.id = n.Id;
      d.needType = n.Need_Type__c;
      d.ruleId = n.Rule_Id__c;
      d.state = n.State__c;
      d.priority = n.Priority__c;
      d.points = n.Points__c;
      d.attemptCount = n.Attempt_Count__c;
      d.nextActionDate = n.Next_Action_Date__c;
      d.snoozeUntil = n.Snooze_Until__c;
      d.scheduleBoundType = n.Schedule_Bound_Type__c;
      d.scheduleEarliest = n.Schedule_Earliest__c;
      d.scheduleLatest = n.Schedule_Latest__c;
      d.schedulePhrase = n.Schedule_Phrase__c;
      d.scheduleStatusLabel = n.Schedule_Status_Label__c;
      needs.get(n.Episode__c).add(d);
    }
    List<RowDTO> result = new List<RowDTO>();
    for (Outreach_Episode__c e : episodes) {
      RowDTO d = new RowDTO();
      d.episodeId = e.Id;
      d.patientId = e.Patient__c;
      d.patientName = e.Patient__r.Name;
      d.clinicName = e.Patient__r.Primary_Clinic__r == null
        ? e.Patient__r.Preferred_Clinic__c
        : e.Patient__r.Primary_Clinic__r.Name;
      d.ownerId = e.OwnerId;
      d.status = e.Status__c;
      d.priority = e.Priority__c;
      d.ownerName = e.Owner.Name;
      d.points = e.Points__c;
      d.nextAction = e.Next_Action__c;
      d.nextActionDate = e.Next_Action_Date__c;
      d.engagementScore = e.Engagement_Score__c;
      d.pressureScore = e.Pressure_Score__c;
      d.pressure = e.Pressure__c;
      d.needs = needs.get(e.Id);
      result.add(d);
    }
    enrichRows(result);
    return result;
  }

  private static void enrichRows(List<RowDTO> rows) {
    if (rows == null || rows.isEmpty())
      return;
    Set<Id> patientIds = new Set<Id>();
    Set<Id> episodeIds = new Set<Id>();
    for (RowDTO row : rows) {
      if (row.patientId != null)
        patientIds.add(row.patientId);
      if (row.episodeId != null)
        episodeIds.add(row.episodeId);
    }
    Map<Id, String> riskTierByPatient = new Map<Id, String>();
    Map<Id, Account> consentByPatient = new Map<Id, Account>();
    if (!patientIds.isEmpty()) {
      for (Account acc : [
        SELECT Id, Risk_Tier__c, PersonHasOptedOutOfEmail, Consent_to_text__c,
               et4ae5__HasOptedOutOfMobile__pc, AI_Outreach_Optout__c, PersonDoNotCall
        FROM Account
        WHERE Id IN :patientIds
        WITH USER_MODE
      ]) {
        riskTierByPatient.put(
          acc.Id,
          String.isBlank(acc.Risk_Tier__c) ? 'Low Risk' : acc.Risk_Tier__c
        );
        consentByPatient.put(acc.Id, acc);
      }
    }
    Map<Id, Patient_Outreach_Profile__c> profilesByPatient = new Map<Id, Patient_Outreach_Profile__c>();
    for (Patient_Outreach_Profile__c profile : [
      SELECT
        Patient__c,
        Episode__c,
        Engagement_Score__c,
        Pressure_Score__c,
        Pressure__c
      FROM Patient_Outreach_Profile__c
      WHERE Patient__c IN :patientIds OR Episode__c IN :episodeIds
      WITH USER_MODE
    ]) {
      if (profile.Patient__c != null)
        profilesByPatient.put(profile.Patient__c, profile);
    }
    Map<String, String> ruleToPolicy = new Map<String, String>();
    Map<String, String> ruleDescriptions = new Map<String, String>();
    Map<String, Outreach_Rule__mdt> rulesById = new Map<String, Outreach_Rule__mdt>();
    for (Outreach_Rule__mdt rule : [
      SELECT
        Rule_Id__c,
        Enabled__c,
        Cadence_Policy__c,
        Description__c,
        Display_Label__c,
        Recommended_Action__c,
        Action_Description__c,
        Force_Acknowledge__c,
        Shadow_Only__c,
        Override_Weekly_Queue_Cooldown__c,
        Override_Daily_Attempt_Limit__c,
        Bypass_Pressure_Gate__c
      FROM Outreach_Rule__mdt
    ]) {
      if (String.isBlank(rule.Rule_Id__c))
        continue;
      rulesById.put(rule.Rule_Id__c, rule);
      if (String.isNotBlank(rule.Cadence_Policy__c))
        ruleToPolicy.put(rule.Rule_Id__c, rule.Cadence_Policy__c);
      if (String.isNotBlank(rule.Description__c))
        ruleDescriptions.put(rule.Rule_Id__c, rule.Description__c);
    }
    Map<String, Integer> policyMaxAttempts = new Map<String, Integer>();
    for (Cadence_Policy__mdt policy : [
      SELECT DeveloperName, Max_Attempts__c
      FROM Cadence_Policy__mdt
    ]) {
      if (policy.Max_Attempts__c != null)
        policyMaxAttempts.put(
          policy.DeveloperName,
          policy.Max_Attempts__c.intValue()
        );
    }
    for (RowDTO row : rows) {
      row.riskTier = riskTierByPatient.get(row.patientId);
      Account ca = consentByPatient.get(row.patientId);
      if (ca != null) {
        row.emailOptedOut = ca.PersonHasOptedOutOfEmail == true;
        row.smsOptedOut =
          ca.et4ae5__HasOptedOutOfMobile__pc == true
          || ca.Consent_to_text__c == false
          || ca.PersonDoNotCall == true;
        row.ai_outreachOptedOut = ca.AI_Outreach_Optout__c == true;
      }
      enrichRow(
        row,
        profilesByPatient.get(row.patientId),
        ruleToPolicy,
        policyMaxAttempts,
        ruleDescriptions,
        rulesById
      );
    }
  }

  private static void enrichRow(
    RowDTO row,
    Patient_Outreach_Profile__c profile,
    Map<String, String> ruleToPolicy,
    Map<String, Integer> policyMaxAttempts,
    Map<String, String> ruleDescriptions,
    Map<String, Outreach_Rule__mdt> rulesById
  ) {
    List<NeedDTO> allNeeds = new List<NeedDTO>();
    if (row.needs != null) {
      for (NeedDTO need : row.needs) {
        if (need == null || String.isBlank(need.ruleId))
          continue;
        Outreach_Rule__mdt ruleMeta = rulesById == null
          ? null
          : rulesById.get(need.ruleId);
        // Drop care gaps when the rule is disabled / missing.
        if (ruleMeta == null || ruleMeta.Enabled__c != true)
          continue;
        allNeeds.add(need);
      }
    }
    row.needs = allNeeds;
    List<NeedDTO> activeNeeds = new List<NeedDTO>();
    for (NeedDTO need : allNeeds) {
      if (
        need.state != 'Superseded' &&
        need.state != 'Shadow' &&
        need.state != 'Silenced' &&
        need.state != 'Resolved'
      )
        activeNeeds.add(need);
    }

    if (rulesById != null && row.needs != null) {
      for (NeedDTO need : row.needs) {
        Outreach_Rule__mdt rule = rulesById.get(need.ruleId);
        if (rule == null)
          continue;
        need.displayLabel = String.isBlank(rule.Display_Label__c)
          ? need.needType
          : rule.Display_Label__c;
        need.recommendedAction = rule.Recommended_Action__c;
        need.actionDescription = rule.Action_Description__c;
        need.forceAcknowledge = rule.Force_Acknowledge__c == true;
        need.selectedByDefault =
          need.state != 'Shadow' &&
          need.state != 'Superseded' &&
          need.state != 'Silenced';
      }
    }
    Integer attemptSum = 0;
    for (NeedDTO need : activeNeeds) {
      Integer attempts = need.attemptCount == null
        ? 0
        : need.attemptCount.intValue();
      attemptSum += attempts;
    }
    List<NeedDTO> rankedNeeds = sortNeedsByWeight(activeNeeds);
    NeedDTO primaryNeed = rankedNeeds.isEmpty() ? null : rankedNeeds[0];
    row.attemptCount = attemptSum;
    // Agent-facing description scopes to pending care gaps the user can see.
    List<NeedDTO> factNeeds = sortNeedsByWeight(activeNeeds);

    Decimal engagement = row.engagementScore;
    Decimal pressureScore = row.pressureScore;
    if (profile != null) {
      if (profile.Engagement_Score__c != null)
        engagement = profile.Engagement_Score__c;
      if (profile.Pressure_Score__c != null)
        pressureScore = profile.Pressure_Score__c;
      if (profile.Pressure__c != null)
        row.pressure = profile.Pressure__c;
    }
    if (engagement != null)
      row.engagementScore = engagement;
    if (pressureScore != null)
      row.pressureScore = pressureScore;
    // Consent chips populated in bulk by enrichRows (no per-row SOQL).
    row.scoreGuidance = guidanceForScores(engagement, pressureScore);

    Integer maxAttempts = resolveMaxAttempts(
      primaryNeed,
      row.priority,
      ruleToPolicy,
      policyMaxAttempts
    );
    row.maxAttempts = maxAttempts;
    row.attemptLabel = attemptSum + ' of ' + maxAttempts;
    row.pressureLabel = pressureScore == null
      ? null
      : String.valueOf(pressureScore.setScale(1));
    row.priorityHeadline = priorityHeadlineFor(row.priority);
    row.rationale = buildRationale(row, factNeeds, ruleDescriptions);
    row.rationaleSource = 'RuleEngine';
    row.recommendedVisit = recommendedVisitFor(activeNeeds);
    if (
      primaryNeed != null && String.isNotBlank(primaryNeed.recommendedAction)
    ) {
      row.recommendedAction = primaryNeed.recommendedAction;
      row.actionDescription = primaryNeed.actionDescription;
    } else {
      row.recommendedAction = row.nextAction;
      row.actionDescription = null;
    }
    row.recommendedActionSource = 'RuleEngine';
    row.rationale = appendCtaToDescription(
      row.rationale,
      row.recommendedAction
    );
    row.scoreChips = buildScoreChips(rankedNeeds, engagement);
    String owner = String.isNotBlank(row.ownerName)
      ? row.ownerName
      : 'PES Outreach';
    row.ownershipGuidance =
      'Owned by ' +
      owner +
      ' — keep on cadence. ' +
      (String.isBlank(row.scoreGuidance) ? '' : row.scoreGuidance);
    row.scheduleSummary = buildScheduleSummary(activeNeeds, row.riskTier);
    applyContactCooldown(row, activeNeeds, rulesById);
  }

  /** Lightweight daily-attempt check (avoids full workspace rebuild in logOutcome). */
  @TestVisible
  static Boolean isDailyAttemptLocked(Id patientId, Id episodeId) {
    if (patientId == null)
      return false;
    Set<String> ruleIds = new Set<String>();
    if (episodeId != null) {
      for (Patient_Need__c n : [
        SELECT Rule_Id__c
        FROM Patient_Need__c
        WHERE
          Episode__c = :episodeId
          AND State__c IN ('Pending', 'In Progress', 'Snoozed')
          AND Rule_Id__c != NULL
        WITH USER_MODE
      ])
        ruleIds.add(n.Rule_Id__c);
    }
    Boolean pressureBypass = false;
    if (!ruleIds.isEmpty()) {
      pressureBypass = [
          SELECT COUNT()
          FROM Outreach_Rule__mdt
          WHERE Rule_Id__c IN :ruleIds AND Bypass_Pressure_Gate__c = TRUE
        ] > 0;
      if (!pressureBypass) {
        Integer overrides = [
          SELECT COUNT()
          FROM Outreach_Rule__mdt
          WHERE Rule_Id__c IN :ruleIds AND Override_Daily_Attempt_Limit__c = TRUE
        ];
        if (overrides > 0)
          return false;
      }
    }
    // Pressure-bypass path may shorten weekly cooldown but never exceeds 1 contact/day.

    Datetime dayStart = Datetime.newInstance(
      Date.today(),
      Time.newInstance(0, 0, 0, 0)
    );
    Integer todayAttempts = [
      SELECT COUNT()
      FROM Outreach_Event__c
      WHERE
        Patient__c = :patientId
        AND Event_At__c >= :dayStart
        AND Event_Type__c IN (
          'Attempt Made',
          'Connected',
          'Appointment Scheduled',
          'Handoff To Marketing'
        )
    ];
    return todayAttempts > 0;
  }

  private static void applyContactCooldown(
    RowDTO row,
    List<NeedDTO> activeNeeds,
    Map<String, Outreach_Rule__mdt> rulesById
  ) {
    row.commentOnlyMode = false;
    row.weeklyCooldownActive = false;
    row.overrideDailyAttempt = false;
    row.cooldownMessage = null;
    if (row.patientId == null)
      return;
    Boolean overrideDaily = false;
    Boolean overrideWeekly = false;
    if (activeNeeds != null && rulesById != null) {
      for (NeedDTO n : activeNeeds) {
        Outreach_Rule__mdt rule = rulesById.get(n.ruleId);
        if (rule == null)
          continue;
        if (rule.Bypass_Pressure_Gate__c == true)
          overrideWeekly = true;
        if (rule.Override_Daily_Attempt_Limit__c == true)
          overrideDaily = true;
        if (rule.Override_Weekly_Queue_Cooldown__c == true)
          overrideWeekly = true;
      }
    }
    if (
      OutreachQueuePolicy.isPressureBlocked(row.pressureScore) &&
      overrideWeekly
    ) {
      // Pressure bypass may shorten weekly cooldown; daily floor remains absolute.
      overrideDaily = false;
    }
    row.overrideDailyAttempt = overrideDaily;
    Datetime dayStart = Datetime.newInstance(
      Date.today(),
      Time.newInstance(0, 0, 0, 0)
    );
    Integer todayAttempts = [
      SELECT COUNT()
      FROM Outreach_Event__c
      WHERE
        Patient__c = :row.patientId
        AND Event_At__c >= :dayStart
        AND Event_Type__c IN (
          'Attempt Made',
          'Connected',
          'Appointment Scheduled',
          'Handoff To Marketing'
        )
    ];
    if (todayAttempts > 0 && !overrideDaily) {
      row.commentOnlyMode = true;
      row.cooldownMessage =
        'Contact attempt already logged today. Comment Only — status and disposition are locked until tomorrow' +
        (overrideWeekly ? '' : '') +
        '.';
    }
    if (
      row.status == 'Snoozed' &&
      row.nextAction != null &&
      row.nextAction.startsWith('Weekly cooldown')
    ) {
      row.weeklyCooldownActive = true;
      if (String.isBlank(row.cooldownMessage))
        row.cooldownMessage = row.nextAction;
    }
  }

  private static Integer resolveMaxAttempts(
    NeedDTO primaryNeed,
    String priority,
    Map<String, String> ruleToPolicy,
    Map<String, Integer> policyMaxAttempts
  ) {
    if (
      primaryNeed != null &&
      String.isNotBlank(primaryNeed.ruleId) &&
      ruleToPolicy.containsKey(primaryNeed.ruleId)
    ) {
      String policyName = ruleToPolicy.get(primaryNeed.ruleId);
      if (policyMaxAttempts.containsKey(policyName))
        return policyMaxAttempts.get(policyName);
    }
    String normalized = String.isBlank(priority) ? 'Routine' : priority;
    if (normalized.equalsIgnoreCase('STAT')) {
      if (policyMaxAttempts.containsKey('STAT_OVERRIDE'))
        return policyMaxAttempts.get('STAT_OVERRIDE');
      return 5;
    }
    if (normalized.equalsIgnoreCase('Urgent')) {
      if (policyMaxAttempts.containsKey('SCHEDULING'))
        return policyMaxAttempts.get('SCHEDULING');
      return 5;
    }
    if (policyMaxAttempts.containsKey('NO_NEXT'))
      return policyMaxAttempts.get('NO_NEXT');
    return 3;
  }

  private static String guidanceForScores(
    Decimal engagement,
    Decimal pressureScore
  ) {
    List<String> parts = new List<String>();
    if (engagement != null) {
      if (engagement >= 50)
        parts.add('Engagement ' + String.valueOf(engagement.setScale(1)) + ' — higher engagement.');
      else if (engagement <= -50)
        parts.add('Engagement ' + String.valueOf(engagement.setScale(1)) + ' — low engagement.');
      else
        parts.add('Engagement ' + String.valueOf(engagement.setScale(1)) + '.');
    }
    if (pressureScore != null) {
      if (OutreachQueuePolicy.isPressureBlocked(pressureScore))
        parts.add(
          'Pressure ' +
          String.valueOf(pressureScore.setScale(1)) +
          ' — at/above block threshold.'
        );
      else
        parts.add('Pressure ' + String.valueOf(pressureScore.setScale(1)) + '.');
    }
    return String.join(parts, ' ');
  }


  private static String priorityHeadlineFor(String priority) {
    if (String.isBlank(priority))
      return 'Routine — On Cadence';
    if (priority.equalsIgnoreCase('STAT'))
      return 'STAT — Priority to Schedule';
    if (priority.equalsIgnoreCase('Urgent'))
      return 'Urgent — Priority to Schedule';
    return 'Routine — On Cadence';
  }

  private static List<NeedDTO> sortNeedsByWeight(List<NeedDTO> needs) {
    List<NeedDTO> ranked = new List<NeedDTO>();
    if (needs != null)
      ranked.addAll(needs);
    ranked.sort(new NeedWeightComparator());
    return ranked;
  }

  private class NeedWeightComparator implements System.Comparator<NeedDTO> {
    public Integer compare(NeedDTO a, NeedDTO b) {
      Integer rankA = priorityRank(a == null ? null : a.priority);
      Integer rankB = priorityRank(b == null ? null : b.priority);
      if (rankA != rankB)
        return rankA < rankB ? -1 : 1;
      Decimal ptsA = a == null || a.points == null ? 0 : a.points;
      Decimal ptsB = b == null || b.points == null ? 0 : b.points;
      if (ptsA == ptsB)
        return 0;
      return ptsA > ptsB ? -1 : 1;
    }
  }

  private static Integer priorityRank(String priority) {
    if (String.isBlank(priority))
      return 2;
    if (priority.equalsIgnoreCase('STAT'))
      return 0;
    if (priority.equalsIgnoreCase('Urgent'))
      return 1;
    return 2;
  }

  private static String friendlyNeedLabel(String needType) {
    String key = needType == null ? '' : needType.trim().toUpperCase();
    if (key.contains('NO_NEXT'))
      return 'no upcoming visit scheduled';
    if (key.contains('AWV'))
      return 'Annual Wellness Visit';
    if (key.contains('OFF_CADENCE'))
      return 'off visit cadence';
    if (key.contains('UNENGAGED') || key.contains('OVERDUE_CONTACT'))
      return 'unengaged / overdue for contact';
    if (String.isBlank(needType))
      return 'an outreach need';
    return titleCaseNeedType(needType);
  }

  private static String friendlyChipLabel(String needType) {
    String key = needType == null ? '' : needType.trim().toUpperCase();
    if (key.contains('NO_NEXT'))
      return 'No next visit';
    if (key.contains('AWV'))
      return 'Annual Wellness Visit';
    if (key.contains('OFF_CADENCE'))
      return 'Off cadence';
    if (key.contains('UNENGAGED') || key.contains('OVERDUE_CONTACT'))
      return 'Unengaged';
    if (String.isBlank(needType))
      return 'Need';
    return titleCaseNeedType(needType);
  }

  private static String titleCaseNeedType(String needType) {
    List<String> parts = needType.replace('_', ' ').toLowerCase().split(' ');
    List<String> titled = new List<String>();
    for (String part : parts) {
      if (String.isBlank(part))
        continue;
      titled.add(part.substring(0, 1).toUpperCase() + part.substring(1));
    }
    return titled.isEmpty() ? needType : String.join(titled, ' ');
  }

  private static String usefulRuleDescription(
    NeedDTO need,
    Map<String, String> ruleDescriptions
  ) {
    if (
      need == null ||
      String.isBlank(need.ruleId) ||
      ruleDescriptions == null ||
      !ruleDescriptions.containsKey(need.ruleId)
    )
      return null;
    String description = ruleDescriptions.get(need.ruleId);
    if (String.isBlank(description))
      return null;
    Integer parallelIdx = description.indexOf('Active parallel mode');
    if (parallelIdx > 0)
      description = description.substring(0, parallelIdx).trim();
    description = description.removeEnd('.').trim();
    if (description.length() == 0 || description.length() > 90)
      return null;
    String lower = description.toLowerCase();
    if (
      lower.contains('predicate') ||
      lower.contains('engine_key') ||
      lower.contains('points__c') ||
      lower.contains('cmdt') ||
      lower.contains('soql')
    )
      return null;
    return description;
  }

  private static String needClause(NeedDTO need) {
    String label = friendlyNeedLabel(need == null ? null : need.needType);
    String priority = need == null || String.isBlank(need.priority)
      ? 'Routine'
      : need.priority;
    String pts = need == null ||
      need.points == null
      ? '0'
      : String.valueOf(need.points.intValue());
    return label + ' (' + priority + ' · ' + pts + ')';
  }

  private static String buildRationale(
    RowDTO row,
    List<NeedDTO> rankedNeeds,
    Map<String, String> ruleDescriptions
  ) {
    String nextAction = String.isBlank(row.nextAction)
      ? 'review the queue'
      : row.nextAction;
    if (rankedNeeds == null || rankedNeeds.isEmpty()) {
      return 'This patient is in the outreach queue.';
    }

    List<String> facts = situationFactsFor(rankedNeeds);
    if (!facts.isEmpty()) {
      return synthesizeSituation(facts);
    }

    NeedDTO primary = rankedNeeds[0];
    String primaryKey = primary.needType == null
      ? ''
      : primary.needType.trim().toUpperCase();
    String lead;
    if (primaryKey.contains('NO_NEXT')) {
      lead = 'This patient has ' + needClause(primary) + '.';
    } else if (primaryKey.contains('AWV')) {
      lead = 'This patient needs outreach for an ' + needClause(primary) + '.';
    } else {
      lead = 'This patient needs outreach for ' + needClause(primary) + '.';
    }

    String alsoText = '';
    if (rankedNeeds.size() > 1) {
      List<String> alsoParts = new List<String>();
      for (Integer i = 1; i < rankedNeeds.size(); i++) {
        alsoParts.add(needClause(rankedNeeds[i]));
      }
      alsoText = ' Also: ' + String.join(alsoParts, '; ') + '.';
    }

    String hintText = '';
    if (!hasHardCodedNeedLabel(primaryKey)) {
      String ruleHint = usefulRuleDescription(primary, ruleDescriptions);
      if (String.isNotBlank(ruleHint))
        hintText = ' ' + ruleHint + '.';
    }

    return lead + alsoText + hintText;
  }

  @TestVisible
  static List<String> situationFactsFor(List<NeedDTO> needs) {
    // Ordered unique facts for natural synthesis.
    String overdue = null;
    Integer overdueRank = 0; // higher wins: 18 > 17 > 12 > 6 > generic
    Boolean offCadence = false;
    Boolean awv = false;
    Boolean noNext = false;
    if (needs == null)
      return new List<String>();
    for (NeedDTO need : needs) {
      String ruleId = need == null ||
        need.ruleId == null
        ? ''
        : need.ruleId.trim().toUpperCase();
      String needType = need == null ||
        need.needType == null
        ? ''
        : need.needType.trim().toUpperCase();
      if (ruleId == 'INACTIVE_18_MONTH' || ruleId.contains('INACTIVE_18')) {
        if (overdueRank < 5) {
          overdue = 'inactive for 18 or more months';
          overdueRank = 5;
        }
      } else if (
        ruleId == 'UNENGAGED_17_MONTH' || ruleId.contains('17_MONTH')
      ) {
        if (overdueRank < 4) {
          overdue = 'more than 17 months overdue for contact';
          overdueRank = 4;
        }
      } else if (
        ruleId == 'UNENGAGED_12_MONTH' || ruleId.contains('12_MONTH')
      ) {
        if (overdueRank < 3) {
          overdue = 'more than 12 months overdue for contact';
          overdueRank = 3;
        }
      } else if (ruleId == 'UNENGAGED_6_MONTH' || ruleId.contains('6_MONTH')) {
        if (overdueRank < 2) {
          overdue = 'more than 6 months overdue for contact';
          overdueRank = 2;
        }
      } else if (
        (needType.contains('UNENGAGED') || ruleId.contains('UNENGAGED')) &&
        overdueRank < 1
      ) {
        overdue = 'overdue for contact';
        overdueRank = 1;
      }
      if (needType.contains('OFF_CADENCE') || ruleId.contains('OFF_CADENCE'))
        offCadence = true;
      if (needType.contains('AWV') || ruleId.contains('AWV'))
        awv = true;
      if (needType.contains('NO_NEXT') || ruleId.contains('NO_NEXT'))
        noNext = true;
    }
    List<String> facts = new List<String>();
    if (String.isNotBlank(overdue))
      facts.add(overdue);
    if (offCadence)
      facts.add('currently not on cadence for their assigned tier');
    if (awv)
      facts.add('due for an Annual Wellness Visit');
    if (noNext)
      facts.add('without a future medical visit scheduled');
    return facts;
  }

  @TestVisible
  static String synthesizeSituation(List<String> facts) {
    if (facts == null || facts.isEmpty())
      return 'The patient needs outreach.';
    Boolean overdue = false;
    Boolean noNext = false;
    Boolean offCadence = false;
    Boolean awv = false;
    String overduePhrase = null;
    for (String f : facts) {
      if (f == null)
        continue;
      String lower = f.toLowerCase();
      if (lower.contains('overdue') || lower.contains('inactive')) {
        overdue = true;
        overduePhrase = f;
      }
      if (
        lower.contains('no next') ||
        lower.contains('without a future medical visit') ||
        lower.contains('no future medical visit')
      )
        noNext = true;
      if (lower.contains('off cadence') || lower.contains('not on cadence'))
        offCadence = true;
      if (lower.contains('annual wellness'))
        awv = true;
    }
    if (overdue && noNext) {
      String whenPart = overduePhrase;
      if (whenPart != null && whenPart.contains('more than 6 months'))
        whenPart = '6+ months overdue';
      else if (whenPart != null && whenPart.contains('more than 12 months'))
        whenPart = '12+ months overdue';
      else if (whenPart != null && whenPart.contains('more than 17 months'))
        whenPart = '17+ months overdue';
      else if (whenPart != null && whenPart.contains('18 or more'))
        whenPart = '18+ months inactive';
      else if (whenPart != null && whenPart.startsWith('more than'))
        whenPart = whenPart.replace('overdue for contact', 'overdue');
      String body =
        'The patient is high risk and ' +
        whenPart +
        ' for an appointment and has no future medical visits scheduled.';
      if (offCadence)
        body =
          'The patient is high risk and ' +
          whenPart +
          ' for an appointment, currently not on cadence for their assigned tier, and has no future medical visits scheduled.';
      return body;
    }
    if (facts.size() == 1)
      return 'The patient is ' + facts[0] + '.';
    if (facts.size() == 2)
      return 'The patient is ' + facts[0] + ' and ' + facts[1] + '.';
    if (facts.size() == 3)
      return 'The patient is ' +
        facts[0] +
        ' and ' +
        facts[1] +
        ' with ' +
        facts[2] +
        '.';
    List<String> head = new List<String>();
    for (Integer i = 0; i < facts.size() - 1; i++)
      head.add(facts[i]);
    return 'The patient is ' +
      String.join(head, ', ') +
      ' with ' +
      facts[facts.size() - 1] +
      '.';
  }

  @TestVisible
  static String situationPhraseFor(NeedDTO need) {
    if (need == null)
      return null;
    String ruleId = need.ruleId == null ? '' : need.ruleId.trim().toUpperCase();
    if (ruleId == 'UNENGAGED_6_MONTH')
      return 'more than 6 months overdue for contact';
    if (ruleId == 'UNENGAGED_12_MONTH')
      return 'more than 12 months overdue for contact';
    if (ruleId == 'UNENGAGED_17_MONTH')
      return 'more than 17 months overdue for contact';
    if (ruleId == 'INACTIVE_18_MONTH')
      return 'inactive for 18 or more months';
    if (ruleId == 'UNENGAGED_OFF_CADENCE')
      return 'currently not on cadence for their assigned tier';
    if (ruleId == 'OFF_CADENCE')
      return 'currently not on cadence for their assigned tier';
    if (ruleId == 'AWV_DUE')
      return 'due for an Annual Wellness Visit';
    if (ruleId.startsWith('NO_NEXT'))
      return 'without a future medical visit scheduled';
    String needType = need.needType == null
      ? ''
      : need.needType.trim().toUpperCase();
    if (needType.contains('NO_NEXT'))
      return 'without a future medical visit scheduled';
    if (needType.contains('AWV'))
      return 'due for an Annual Wellness Visit';
    if (needType.contains('OFF_CADENCE'))
      return 'currently not on cadence for their assigned tier';
    if (needType.contains('UNENGAGED'))
      return 'overdue for contact';
    return friendlyNeedLabel(need.needType);
  }

  private static Boolean hasHardCodedNeedLabel(String needKey) {
    if (String.isBlank(needKey))
      return false;
    return needKey.contains('NO_NEXT') ||
      needKey.contains('AWV') ||
      needKey.contains('OFF_CADENCE') ||
      needKey.contains('UNENGAGED') ||
      needKey.contains('OVERDUE_CONTACT');
  }

  private static String recommendedVisitFor(List<NeedDTO> activeNeeds) {
    Boolean hasAwv = false;
    Boolean hasOffCadence = false;
    Boolean hasNoNext = false;
    for (NeedDTO need : activeNeeds) {
      String needType = need.needType == null
        ? ''
        : need.needType.toUpperCase();
      if (needType.contains('AWV'))
        hasAwv = true;
      else if (needType.contains('OFF_CADENCE'))
        hasOffCadence = true;
      else if (needType.contains('NO_NEXT'))
        hasNoNext = true;
    }
    if (hasAwv)
      return 'Annual Wellness Visit (AWV)';
    if (hasOffCadence)
      return 'Primary care follow-up';
    if (hasNoNext)
      return 'Schedule next visit';
    return null;
  }

  private static List<ScoreChipDTO> buildScoreChips(
    List<NeedDTO> activeNeeds,
    Decimal engagement
  ) {
    List<ScoreChipDTO> chips = new List<ScoreChipDTO>();
    for (NeedDTO need : activeNeeds) {
      if (chips.size() >= 4)
        break;
      ScoreChipDTO chip = new ScoreChipDTO();
      String priority = String.isBlank(need.priority)
        ? 'Routine'
        : need.priority;
      chip.label = friendlyChipLabel(need.needType) + ' · ' + priority;
      chip.points = need.points;
      chips.add(chip);
    }
    if (chips.size() < 4 && engagement != null) {
      ScoreChipDTO engagementChip = new ScoreChipDTO();
      engagementChip.label = 'Engagement';
      engagementChip.points = engagement;
      chips.add(engagementChip);
    }
    return chips;
  }
}