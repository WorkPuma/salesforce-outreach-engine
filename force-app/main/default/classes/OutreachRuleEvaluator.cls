public inherited sharing class OutreachRuleEvaluator {
  private static final Set<String> ACTIVE_STATES = new Set<String>{
    'Pending',
    'In Progress',
    'Snoozed'
  };

  public static List<Outreach_Rule__mdt> activeRules() {
    Date today = Date.today();
    List<Outreach_Rule__mdt> effective = new List<Outreach_Rule__mdt>();
    for (Outreach_Rule__mdt rule : [
      SELECT
        Rule_Id__c,
        Version__c,
        Need_Type__c,
        Category__c,
        Shadow_Only__c,
        Effective_Start__c,
        Effective_End__c,
        Family__c,
        Supersedes_Families__c,
        Use_Global_Cadence__c
      FROM Outreach_Rule__mdt
      WHERE Enabled__c = TRUE
      WITH SECURITY_ENFORCED
      ORDER BY Rule_Id__c
    ]) {
      if (
        (rule.Effective_Start__c == null || rule.Effective_Start__c <= today) &&
        (rule.Effective_End__c == null ||
        rule.Effective_End__c >= today)
      )
        effective.add(rule);
    }
    return effective;
  }

  public static List<Patient_Need__c> evaluate(Set<Id> accountIds) {
    if (accountIds == null || accountIds.isEmpty())
      return new List<Patient_Need__c>();
    if (!OutreachRulesEngineClient.isEnabled())
      throw new OutreachRuleException(
        'RulesEngine eligibility is not enabled (Outreach_RulesEngine_Settings.Default.Enabled__c).'
      );

    Map<Id, Account> accounts = new Map<Id, Account>(
      [
        SELECT Id, Department_Id__c
        FROM Account
        WHERE Id IN :accountIds
        WITH SECURITY_ENFORCED
      ]
    );
    // Global rule: never create/refresh care items for MIDI or Vaccine Clinic.
    Set<Id> excludedIds = new Set<Id>();
    for (Id accountId : new List<Id>(accounts.keySet())) {
      if (MIDIExclusionUtils.isOutreachExcluded(accounts.get(accountId))) {
        excludedIds.add(accountId);
        accounts.remove(accountId);
      }
    }
    if (!excludedIds.isEmpty())
      closeExcludedClinicNeeds(excludedIds);
    if (accounts.isEmpty())
      return new List<Patient_Need__c>();

    Set<Id> eligibleIds = accounts.keySet();
    Map<String, Patient_Need__c> existing = new Map<String, Patient_Need__c>();
    for (Patient_Need__c n : [
      SELECT
        Id,
        Engine_Key__c,
        Patient__c,
        State__c,
        Attempt_Count__c,
        Snooze_Until__c,
        Next_Action_Date__c,
        Resolution_Reason__c,
        Episode__c,
        Rule_Id__c,
        Shadow__c
      FROM Patient_Need__c
      WHERE Patient__c IN :eligibleIds
      WITH SECURITY_ENFORCED
    ])
      existing.put(n.Engine_Key__c, n);

    return evaluateViaRulesEngine(
      accounts,
      existing,
      activeSuppressions(eligibleIds),
      activeRules()
    );
  }

  /**
   * Resolve any active/open needs for MIDI / Vaccine Clinic patients.
   * Prefer delete for bulk historical cleanup; this path covers re-eval safety.
   */
  @TestVisible
  static void closeExcludedClinicNeeds(Set<Id> accountIds) {
    if (accountIds == null || accountIds.isEmpty())
      return;
    List<Patient_Need__c> toClose = new List<Patient_Need__c>();
    for (Patient_Need__c n : [
      SELECT Id, State__c
      FROM Patient_Need__c
      WHERE
        Patient__c IN :accountIds
        AND State__c IN (
          'Pending',
          'In Progress',
          'Snoozed',
          'Suppressed',
          'Shadow',
          'Superseded'
        )
      WITH SECURITY_ENFORCED
    ]) {
      n.State__c = 'Resolved';
      n.Resolution_Reason__c = 'Excluded clinic (MIDI/Vaccine Clinic)';
      n.Next_Action_Date__c = null;
      n.Snooze_Until__c = null;
      toClose.add(n);
    }
    if (!toClose.isEmpty()) {
      if (!Schema.sObjectType.Patient_Need__c.isUpdateable())
        throw new OutreachRuleException('Patient Need write access is required.');
      update toClose;
    }
  }

  @TestVisible
  static Date parseIsoDate(String iso) {
    if (String.isBlank(iso))
      return null;
    try {
      List<String> parts = iso.split('-');
      if (parts.size() != 3)
        return null;
      return Date.newInstance(
        Integer.valueOf(parts[0]),
        Integer.valueOf(parts[1]),
        Integer.valueOf(parts[2])
      );
    } catch (Exception e) {
      return null;
    }
  }

  @TestVisible
  static Date computeScheduleLatestFromOffset(
    Map<String, Object> facts,
    Integer offsetDays
  ) {
    if (facts == null || offsetDays == null)
      return null;
    Object raw = facts.get('lastCompletedVisitDate');
    Date base = parseIsoDate(raw == null ? null : String.valueOf(raw));
    if (base == null)
      return null;
    // Keep the true cadence end date (may be in the past) so PES guidance
    // shows the real on-cadence window, not the Exceeds/+15% gate.
    return base.addDays(offsetDays);
  }

  static void applyScheduleFromHit(
    Patient_Need__c n,
    OutreachRulesEngineClient.SurfaceHit hit,
    Map<String, Object> facts
  ) {
    n.Schedule_Bound_Type__c = hit.scheduleBoundType;
    Date earliest = parseIsoDate(hit.scheduleEarliest);
    // ANYTIME_AFTER windows that opened in the past are actionable now.
    if (
      earliest != null &&
      String.isNotBlank(hit.scheduleBoundType) &&
      hit.scheduleBoundType.trim().toUpperCase() == 'ANYTIME_AFTER' &&
      earliest < Date.today()
    ) {
      earliest = Date.today();
    }
    n.Schedule_Earliest__c = earliest;
    n.Schedule_Phrase__c = hit.schedulePhrase;
    n.Schedule_Status_Label__c = hit.statusLabel;
    Date latest = parseIsoDate(hit.scheduleLatest);
    if (latest == null && hit.scheduleLatestOffsetDays != null)
      latest = computeScheduleLatestFromOffset(
        facts,
        hit.scheduleLatestOffsetDays
      );
    n.Schedule_Latest__c = latest;
  }

  static String preservedState(Patient_Need__c prior, Boolean shadow) {
    if (shadow)
      return 'Shadow';
    if (prior != null && prior.State__c == 'Snoozed')
      return prior.Snooze_Until__c != null &&
        prior.Snooze_Until__c > System.now()
        ? 'Snoozed'
        : 'Pending';
    return prior != null && ACTIVE_STATES.contains(prior.State__c)
      ? prior.State__c
      : 'Pending';
  }
  @TestVisible
  static void applyPreservedState(
    Patient_Need__c target,
    Patient_Need__c prior,
    Boolean shadow
  ) {
    if (
      prior != null &&
      prior.State__c == 'Resolved' &&
      prior.Resolution_Reason__c == 'Max attempts reached'
    ) {
      target.State__c = 'Resolved';
      target.Attempt_Count__c = prior.Attempt_Count__c;
      target.Resolution_Reason__c = 'Max attempts reached';
      target.Snooze_Until__c = null;
      target.Next_Action_Date__c = null;
      return;
    }
    if (prior != null && prior.State__c == 'Resolved') {
      target.State__c = shadow ? 'Shadow' : 'Pending';
      target.Attempt_Count__c = 0;
      target.Resolution_Reason__c = null;
      target.Snooze_Until__c = null;
      target.Next_Action_Date__c = Date.today();
      return;
    }
    target.State__c = preservedState(prior, shadow);
    if (prior != null)
      target.Attempt_Count__c = prior.Attempt_Count__c;
    if (prior != null && prior.Snooze_Until__c != null)
      target.Snooze_Until__c = target.State__c == 'Snoozed'
        ? prior.Snooze_Until__c
        : null;
  }


  /**
   * Hard gate for No Next (authoritative over RulesEngine surface until JDM updated):
   * active (a) + no future appointment + at least one completed visit.
   */
  @TestVisible
  static Boolean passesNoNextEligibility(Map<String, Object> facts) {
    if (facts == null)
      return false;
    Boolean isActiveA = facts.get('isActiveA') == true;
    Decimal futureCount = 0;
    Object fut = facts.get('futureApptCount');
    if (fut != null)
      futureCount = Decimal.valueOf(String.valueOf(fut));
    Decimal completedCount = 0;
    Object comp = facts.get('completedApptCount');
    if (comp != null)
      completedCount = Decimal.valueOf(String.valueOf(comp));
    return isActiveA && futureCount == 0 && completedCount >= 1;
  }

  static Boolean isNoNextHit(OutreachRulesEngineClient.SurfaceHit hit, Outreach_Rule__mdt rule) {
    if (hit == null)
      return false;
    if (String.isNotBlank(hit.needType) && hit.needType == 'NO_NEXT')
      return true;
    if (String.isNotBlank(hit.family) && hit.family == 'NO_NEXT')
      return true;
    if (String.isNotBlank(hit.ruleId) && hit.ruleId.startsWith('NO_NEXT'))
      return true;
    return rule != null && rule.Need_Type__c == 'NO_NEXT';
  }

  @TestVisible
  static List<Patient_Need__c> evaluateViaRulesEngine(
    Map<Id, Account> accounts,
    Map<String, Patient_Need__c> existing,
    Set<String> suppressed,
    List<Outreach_Rule__mdt> rules
  ) {
    Map<String, Outreach_Rule__mdt> byRuleId = new Map<String, Outreach_Rule__mdt>();
    for (Outreach_Rule__mdt rule : rules)
      byRuleId.put(rule.Rule_Id__c, rule);

    Map<Id, Map<String, Object>> factsByAccount = OutreachRulesEngineFactBuilder.buildForAccounts(
      accounts.keySet(),
      suppressed
    );
    Set<String> matched = new Set<String>();
    List<Patient_Need__c> writes = new List<Patient_Need__c>(),
      opened = new List<Patient_Need__c>(),
      closed = new List<Patient_Need__c>();

    for (Id accountId : accounts.keySet()) {
      Map<String, Object> facts = factsByAccount.get(accountId);
      if (facts == null)
        continue;
      List<OutreachRulesEngineClient.SurfaceHit> hits = OutreachRulesEngineClient.evaluateSurface(
        facts
      );
      hits.addAll(OutreachLocalSurfaceRules.evaluate(facts));
      Boolean currentlyAdmitted = facts.get('currentlyAdmitted') == true;
      for (OutreachRulesEngineClient.SurfaceHit hit : hits) {
        Outreach_Rule__mdt rule = byRuleId.get(hit.ruleId);
        // While admitted, do not open/refresh scheduling No Next (admission/TCM supersede)
        if (currentlyAdmitted && isNoNextHit(hit, rule))
          continue;
        // Enforce No Next business rule in Apex (active + no future + completed>=1)
        if (isNoNextHit(hit, rule) && !passesNoNextEligibility(facts))
          continue;
        String version = rule == null || rule.Version__c == null
          ? '1'
          : String.valueOf(rule.Version__c);
        String key = needKey(accountId, hit.ruleId, version);
        matched.add(key);
        Patient_Need__c prior = existing.get(key);
        Patient_Need__c n = prior == null
          ? new Patient_Need__c()
          : new Patient_Need__c(Id = prior.Id);
        n.Engine_Key__c = key;
        n.Patient__c = accountId;
        n.Rule_Id__c = hit.ruleId;
        n.Rule_Version__c = version;
        if (String.isBlank(hit.priority) || hit.points == null) {
          throw new OutreachRulesEngineClient.RulesEngineException(
            'RulesEngine surface hit for ' +
              hit.ruleId +
              ' must include priority and points.'
          );
        }
        n.Need_Type__c = String.isNotBlank(hit.needType)
          ? hit.needType
          : (rule == null ? hit.ruleId : rule.Need_Type__c);
        n.Category__c = String.isNotBlank(hit.category)
          ? hit.category
          : (rule == null ? null : rule.Category__c);
        n.Priority__c = hit.priority;
        n.Points__c = hit.points;
        Boolean shadow = hit.shadowOnly == true || hit.createWork == false;
        n.Shadow__c = shadow;
        n.Next_Action_Date__c = Date.today();
        n.Eligibility_Snapshot__c = JSON.serialize(
          new Map<String, Object>{
            'matchMode' => 'RULESENGINE',
            'ruleId' => hit.ruleId,
            'family' => hit.family,
            'version' => version,
            'evaluatedOn' => Date.today()
          }
        );
        String suppressKey = accountId + ':' + n.Need_Type__c;
        if (suppressed.contains(suppressKey))
          n.State__c = 'Suppressed';
        else
          applyPreservedState(n, prior, shadow);
        applyScheduleFromHit(n, hit, facts);
        writes.add(n);
        if (
          (prior == null || !ACTIVE_STATES.contains(prior.State__c)) &&
          ACTIVE_STATES.contains(n.State__c)
        )
          opened.add(n);
      }
    }

    applyFamilySupersedence(writes, rules);
    for (Patient_Need__c prior : existing.values()) {
      if (matched.contains(prior.Engine_Key__c))
        continue;
      Boolean wasActive =
        ACTIVE_STATES.contains(prior.State__c) ||
        prior.State__c == 'Suppressed' ||
        prior.State__c == 'Superseded' ||
        prior.State__c == 'Shadow';
      Boolean wasExhausted =
        prior.State__c == 'Resolved' &&
        prior.Resolution_Reason__c == 'Max attempts reached';
      if (!wasActive && !wasExhausted)
        continue;
      prior.State__c = 'Resolved';
      prior.Resolution_Reason__c = 'Eligibility RulesEngine no longer matches';
      prior.Snooze_Until__c = null;
      prior.Next_Action_Date__c = null;
      writes.add(prior);
      if (wasActive)
        closed.add(prior);
    }
    if (!writes.isEmpty()) {
      if (
        !Schema.sObjectType.Patient_Need__c.isCreateable() ||
        !Schema.sObjectType.Patient_Need__c.isUpdateable()
      )
        throw new OutreachRuleException(
          'Patient Need write access is required.'
        );
      upsert writes Patient_Need__c.Engine_Key__c;
    }
    OutreachEventService.recordNeedLifecycle(opened, closed);
    return [
      SELECT
        Id,
        Engine_Key__c,
        Patient__c,
        Rule_Id__c,
        Need_Type__c,
        State__c,
        Points__c,
        Priority__c,
        Shadow__c,
        Attempt_Count__c,
        Next_Action_Date__c,
        Snooze_Until__c,
        Episode__c
      FROM Patient_Need__c
      WHERE Patient__c IN :accounts.keySet()
      WITH SECURITY_ENFORCED
    ];
  }

  @TestVisible
  static void applyFamilySupersedence(
    List<Patient_Need__c> writes,
    List<Outreach_Rule__mdt> rules
  ) {
    if (writes == null || writes.isEmpty() || rules == null || rules.isEmpty())
      return;
    Map<String, String> familyByRule = new Map<String, String>();
    Map<String, Set<String>> supersedesByRule = new Map<String, Set<String>>();
    for (Outreach_Rule__mdt rule : rules) {
      if (String.isBlank(rule.Rule_Id__c))
        continue;
      String family = String.isBlank(rule.Family__c)
        ? rule.Need_Type__c
        : rule.Family__c;
      familyByRule.put(
        rule.Rule_Id__c,
        family == null ? '' : family.trim().toUpperCase()
      );
      Set<String> targets = new Set<String>();
      if (String.isNotBlank(rule.Supersedes_Families__c)) {
        for (String part : rule.Supersedes_Families__c.split(',')) {
          if (String.isNotBlank(part))
            targets.add(part.trim().toUpperCase());
        }
      }
      supersedesByRule.put(rule.Rule_Id__c, targets);
    }
    Map<Id, List<Patient_Need__c>> byPatient = new Map<Id, List<Patient_Need__c>>();
    for (Patient_Need__c n : writes) {
      if (n.Patient__c == null || String.isBlank(n.Rule_Id__c))
        continue;
      if (
        n.State__c == 'Suppressed' ||
        n.State__c == 'Shadow' ||
        n.State__c == 'Resolved' ||
        n.State__c == 'Cancelled'
      )
        continue;
      if (!byPatient.containsKey(n.Patient__c))
        byPatient.put(n.Patient__c, new List<Patient_Need__c>());
      byPatient.get(n.Patient__c).add(n);
    }
    for (List<Patient_Need__c> needs : byPatient.values()) {
      // 1) Cross-family supersedence (e.g. UNENGAGED hides NO_NEXT)
      Set<String> hiddenFamilies = new Set<String>();
      for (Patient_Need__c n : needs) {
        Set<String> targets = supersedesByRule.get(n.Rule_Id__c);
        if (targets != null)
          hiddenFamilies.addAll(targets);
      }
      Map<String, Patient_Need__c> familyWinner = new Map<String, Patient_Need__c>();
      for (Patient_Need__c n : needs) {
        String family = familyByRule.containsKey(n.Rule_Id__c)
          ? familyByRule.get(n.Rule_Id__c)
          : (n.Need_Type__c == null ? '' : n.Need_Type__c.trim().toUpperCase());
        if (String.isBlank(family))
          continue;
        if (hiddenFamilies.contains(family))
          continue; // will be superseded below
        Patient_Need__c current = familyWinner.get(family);
        if (current == null) {
          familyWinner.put(family, n);
        } else {
          Decimal curPts = current.Points__c == null ? 0 : current.Points__c;
          Decimal newPts = n.Points__c == null ? 0 : n.Points__c;
          if (newPts > curPts)
            familyWinner.put(family, n);
        }
      }
      Set<Id> winnerKeys = new Set<Id>();
      Set<String> winnerEngineKeys = new Set<String>();
      for (Patient_Need__c winner : familyWinner.values()) {
        if (winner.Id != null)
          winnerKeys.add(winner.Id);
        if (String.isNotBlank(winner.Engine_Key__c))
          winnerEngineKeys.add(winner.Engine_Key__c);
      }
      for (Patient_Need__c n : needs) {
        String family = familyByRule.containsKey(n.Rule_Id__c)
          ? familyByRule.get(n.Rule_Id__c)
          : (n.Need_Type__c == null ? '' : n.Need_Type__c.trim().toUpperCase());
        Boolean hiddenByFamily =
          String.isNotBlank(family) && hiddenFamilies.contains(family);
        Boolean isWinner =
          (n.Id != null && winnerKeys.contains(n.Id)) ||
          (String.isNotBlank(n.Engine_Key__c) &&
          winnerEngineKeys.contains(n.Engine_Key__c));
        // Same-family variants that are not the points winner also collapse.
        Boolean sameFamilyLoser =
          String.isNotBlank(family) &&
          familyWinner.containsKey(family) &&
          !isWinner &&
          !hiddenByFamily;
        if (hiddenByFamily || sameFamilyLoser) {
          n.State__c = 'Superseded';
          n.Resolution_Reason__c = hiddenByFamily
            ? 'Superseded by related rule family'
            : 'Superseded by higher-weight variant in the same family';
        } else if (n.State__c == 'Superseded') {
          n.State__c = 'Pending';
          n.Resolution_Reason__c = null;
        }
      }
    }
  }

  private static String needKey(Id id, String rule, String version) {
    return String.valueOf(id) + ':' + rule + ':' + version;
  }
  public class OutreachRuleException extends Exception {
  }
  private static Set<String> activeSuppressions(Set<Id> ids) {
    Set<String> result = new Set<String>();
    Date today = Date.today();
    for (Suppression__c s : [
      SELECT Patient__c, Need_Type__c
      FROM Suppression__c
      WHERE
        Patient__c IN :ids
        AND Active__c = TRUE
        AND (Effective_Start__c = NULL
        OR Effective_Start__c <= :today)
        AND (Expires_On__c = NULL
        OR Expires_On__c >= :today)
        AND (Channel__c = NULL
        OR Channel__c = ''
        OR Channel__c = 'All')
      WITH SECURITY_ENFORCED
    ])
      result.add(s.Patient__c + ':' + s.Need_Type__c);
    return result;
  }
}