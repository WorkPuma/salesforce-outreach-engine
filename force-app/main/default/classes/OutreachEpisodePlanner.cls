public inherited sharing class OutreachEpisodePlanner {
  private static final Set<String> ACTIVE_STATES = new Set<String>{
    'Pending',
    'In Progress',
    'Snoozed'
  };
  private static final Integer WEEKLY_QUEUE_COOLDOWN_DAYS = 7;
  private static final Integer OVERRIDE_MIN_RESURFACE_DAYS = 1;
  private static final Set<String> CONTACT_EVENT_TYPES = new Set<String>{
    'Attempt Made',
    'Connected',
    'Appointment Scheduled',
    'Handoff To Marketing'
  };

  public static List<Outreach_Episode__c> plan(Set<Id> patientIds) {
    if (patientIds == null || patientIds.isEmpty())
      return new List<Outreach_Episode__c>();
    Map<Id, List<Patient_Need__c>> byPatient = new Map<Id, List<Patient_Need__c>>();
    for (Id id : patientIds)
      byPatient.put(id, new List<Patient_Need__c>());
    for (Patient_Need__c n : [
      SELECT
        Id,
        Patient__c,
        Priority__c,
        Points__c,
        Next_Action_Date__c,
        State__c,
        Snooze_Until__c,
        Rule_Id__c,
        Attempt_Count__c
      FROM Patient_Need__c
      WHERE Patient__c IN :patientIds AND State__c IN :ACTIVE_STATES
      WITH SECURITY_ENFORCED
    ])
      byPatient.get(n.Patient__c).add(n);

    Map<Id, Account> accountsById = new Map<Id, Account>(
      [
        SELECT Id, Engagement_Score__c, Pressure_Score__c
        FROM Account
        WHERE Id IN :patientIds
      ]
    );

    Map<String, Set<String>> bypassRulesByPatient = bypassPressureRulesByPatient(
      byPatient
    );
    Map<Id, Datetime> lastContactByPatient = lastContactByPatient(patientIds);
    Set<String> weeklyOverrideRuleIds = weeklyOverrideRuleIds(byPatient);

    Map<String, Outreach_Episode__c> existing = new Map<String, Outreach_Episode__c>();
    for (Outreach_Episode__c e : [
      SELECT Id, Engine_Key__c, OwnerId, Status__c, Engagement_Score__c, Pressure__c, Pressure_Score__c
      FROM Outreach_Episode__c
      WHERE Patient__c IN :patientIds
    ])
      existing.put(e.Engine_Key__c, e);

    Id queueId = [
      SELECT Id
      FROM Group
      WHERE Type = 'Queue' AND DeveloperName = 'PES_Outreach'
      WITH SECURITY_ENFORCED
      LIMIT 1
    ]
    .Id;

    List<Outreach_Episode__c> writes = new List<Outreach_Episode__c>();
    for (Id patientId : patientIds) {
      String key = episodeKey(patientId);
      Outreach_Episode__c prior = existing.get(key);
      Outreach_Episode__c e = prior == null
        ? new Outreach_Episode__c()
        : new Outreach_Episode__c(Id = prior.Id);
      e.Engine_Key__c = key;
      e.Patient__c = patientId;

      Account acct = accountsById.get(patientId);
      Decimal eng = acct == null ? null : acct.Engagement_Score__c;
      Decimal pressScore = acct == null ? null : acct.Pressure_Score__c;
      e.Engagement_Score__c = eng;
      e.Pressure_Score__c = pressScore;

      List<Patient_Need__c> needs = byPatient.get(patientId);
      if (needs.isEmpty()) {
        if (prior != null) {
          e.Status__c = 'Completed';
          e.Next_Action__c = 'No active needs';
          writes.add(e);
        }
        continue;
      }

      List<Patient_Need__c> actionable = new List<Patient_Need__c>();
      Datetime earliestWake;
      Decimal maxPoints = 0;
      for (Patient_Need__c n : needs) {
        if (value(n.Points__c) > value(maxPoints))
          maxPoints = n.Points__c;
        Boolean futureSnoozed =
          n.State__c == 'Snoozed' &&
          n.Snooze_Until__c != null &&
          n.Snooze_Until__c > System.now();
        if (futureSnoozed) {
          if (earliestWake == null || n.Snooze_Until__c < earliestWake)
            earliestWake = n.Snooze_Until__c;
        } else {
          actionable.add(n);
        }
      }
      List<Patient_Need__c> priorityNeeds = actionable.isEmpty()
        ? needs
        : actionable;
      Patient_Need__c primary = priorityNeeds[0];
      Date earliest = primary.Next_Action_Date__c;
      for (Patient_Need__c n : priorityNeeds) {
        if (
          priorityRank(n.Priority__c) < priorityRank(primary.Priority__c) ||
          (priorityRank(n.Priority__c) == priorityRank(primary.Priority__c) &&
          value(n.Points__c) > value(primary.Points__c))
        )
          primary = n;
        if (
          earliest == null ||
          (n.Next_Action_Date__c != null && n.Next_Action_Date__c < earliest)
        )
          earliest = n.Next_Action_Date__c;
      }
      e.Priority__c = primary.Priority__c;
      e.Points__c = maxPoints;
      e.Primary_Rule_Id__c = primary.Rule_Id__c;
      e.Routing_Priority__c = OutreachRoutingPriority.calculate(
        primary.Priority__c,
        maxPoints,
        earliest,
        eng,
        patientId
      );
      e.Shadow__c = false;

      if (actionable.isEmpty()) {
        e.Status__c = 'Snoozed';
        e.Next_Action_Date__c = earliestWake == null
          ? Date.today()
          : earliestWake.date();
        e.Next_Action__c =
          'Snoozed — wake ' + String.valueOf(e.Next_Action_Date__c);
        e.OwnerId = prior != null &&
          prior.Status__c != 'Completed' &&
          prior.Status__c != 'Cancelled'
          ? prior.OwnerId
          : queueId;
      } else {
        e.Next_Action_Date__c = earliest == null ? Date.today() : earliest;
        e.Next_Action__c = primary.Priority__c == 'STAT'
          ? 'Call — prioritize today'
          : 'Call — schedule visit';
        if (
          prior == null ||
          prior.Status__c == 'Completed' ||
          prior.Status__c == 'Cancelled'
        ) {
          e.Status__c = 'Unclaimed';
          e.OwnerId = queueId;
        } else if (prior.Status__c == 'Snoozed') {
          e.Status__c = 'Unclaimed';
          e.OwnerId = queueId;
        } else {
          e.Status__c = prior.Status__c;
          e.OwnerId = prior.OwnerId;
        }
      }

      Boolean bypassPressure = bypassRulesByPatient.containsKey(
        String.valueOf(patientId)
      ) && !bypassRulesByPatient.get(String.valueOf(patientId)).isEmpty();
      applyPressureGate(e, pressScore, bypassPressure);
      Boolean weeklyOverride = bypassPressure;
      if (!weeklyOverride) {
        for (Patient_Need__c n : actionable) {
          if (weeklyOverrideRuleIds.contains(n.Rule_Id__c)) {
            weeklyOverride = true;
            break;
          }
        }
      }
      applyWeeklyQueueCooldown(
        e,
        weeklyOverride,
        lastContactByPatient.get(patientId)
      );
      writes.add(e);
    }

    if (!writes.isEmpty()) {
      if (
        !Schema.sObjectType.Outreach_Episode__c.isCreateable() ||
        !Schema.sObjectType.Outreach_Episode__c.isUpdateable()
      )
        throw new OutreachPlannerException('Episode write access is required.');
      upsert writes Outreach_Episode__c.Engine_Key__c;
      Set<Id> routedIds = new Set<Id>();
      for (Outreach_Episode__c routed : writes)
        if (routed.Status__c == 'Unclaimed')
          routedIds.add(routed.Id);
      OutreachOmniRoutingService.routeIfEnabled(routedIds);
    }

    Map<Id, Id> episodeByPatient = new Map<Id, Id>();
    Set<Id> episodeIds = new Set<Id>();
    for (Outreach_Episode__c e : writes)
      if (e.Status__c != 'Completed') {
        episodeByPatient.put(e.Patient__c, e.Id);
        episodeIds.add(e.Id);
      }
    List<Patient_Need__c> needLinks = new List<Patient_Need__c>();
    Set<Id> activePatientIds = episodeByPatient.keySet();
    Set<String> linkStates = new Set<String>(ACTIVE_STATES);
    linkStates.add('Superseded');
    for (Patient_Need__c n : [
      SELECT Id, Patient__c, Episode__c
      FROM Patient_Need__c
      WHERE Patient__c IN :activePatientIds AND State__c IN :linkStates
      WITH SECURITY_ENFORCED
    ])
      if (n.Episode__c != episodeByPatient.get(n.Patient__c)) {
        n.Episode__c = episodeByPatient.get(n.Patient__c);
        needLinks.add(n);
      }
    if (!needLinks.isEmpty()) {
      if (!Schema.sObjectType.Patient_Need__c.isUpdateable())
        throw new OutreachPlannerException(
          'Patient Need update access is required.'
        );
      update needLinks;
    }
    project(patientIds, writes, byPatient, episodeIds, accountsById);
    return writes;
  }

  private static void project(
    Set<Id> patientIds,
    List<Outreach_Episode__c> episodes,
    Map<Id, List<Patient_Need__c>> needs,
    Set<Id> episodeIds,
    Map<Id, Account> accountsById
  ) {
    Map<Id, OutreachEventService.Metrics> metrics = OutreachEventService.calculateMetrics(
      episodeIds
    );
    Map<Id, Outreach_Episode__c> activeByPatient = new Map<Id, Outreach_Episode__c>();
    for (Outreach_Episode__c e : episodes)
      if (e.Status__c != 'Completed')
        activeByPatient.put(e.Patient__c, e);
    List<Patient_Outreach_Profile__c> profiles = new List<Patient_Outreach_Profile__c>();
    for (Id patientId : patientIds) {
      Outreach_Episode__c e = activeByPatient.get(patientId);
      OutreachEventService.Metrics m = e == null ? null : metrics.get(e.Id);
      Account acct = accountsById.get(patientId);
      Decimal eng = acct == null ? null : acct.Engagement_Score__c;
      Decimal pressScore = acct == null ? null : acct.Pressure_Score__c;
      Integer attempts = m == null ? 0 : m.attemptCount;
      profiles.add(
        new Patient_Outreach_Profile__c(
          Engine_Key__c = String.valueOf(patientId),
          Patient__c = patientId,
          Episode__c = e == null ? null : e.Id,
          Active_Need_Count__c = needs.get(patientId).size(),
          Priority__c = e == null ? null : e.Priority__c,
          Points__c = e == null ? 0 : e.Points__c,
          Next_Action__c = e == null ? 'No active needs' : e.Next_Action__c,
          Next_Action_Date__c = e == null ? null : e.Next_Action_Date__c,
          Engagement_Score__c = eng,
          Pressure_Score__c = pressScore,
          Pressure__c = attempts,
          Last_Evaluated_At__c = System.now()
        )
      );
      if (e != null && e.Id != null) {
        // Keep episode attempt counter in sync without clobbering Account scores.
        e.Pressure__c = attempts;
      }
    }
    if (!profiles.isEmpty()) {
      if (
        !Schema.sObjectType.Patient_Outreach_Profile__c.isCreateable() ||
        !Schema.sObjectType.Patient_Outreach_Profile__c.isUpdateable()
      )
        throw new OutreachPlannerException(
          'Profile write access is required.'
        );
      upsert profiles Patient_Outreach_Profile__c.Engine_Key__c;
    }
    List<Outreach_Episode__c> attemptUpdates = new List<Outreach_Episode__c>();
    for (Outreach_Episode__c e : episodes) {
      if (e.Id == null || e.Status__c == 'Completed')
        continue;
      attemptUpdates.add(
        new Outreach_Episode__c(Id = e.Id, Pressure__c = e.Pressure__c)
      );
    }
    if (!attemptUpdates.isEmpty())
      update attemptUpdates;
  }

  /** Hold high-pressure patients out of Unclaimed unless a rule bypasses. */
  @TestVisible
  static void applyPressureGate(
    Outreach_Episode__c e,
    Decimal pressureScore,
    Boolean bypassPressure
  ) {
    if (e == null)
      return;
    if (
      e.Status__c == 'Completed' ||
      e.Status__c == 'Cancelled' ||
      e.Status__c == 'Snoozed'
    )
      return;
    if (!OutreachQueuePolicy.isPressureBlocked(pressureScore))
      return;
    if (bypassPressure == true)
      return;
    e.Status__c = 'Snoozed';
    e.Next_Action_Date__c = Date.today().addDays(1);
    e.Next_Action__c =
      'Pressure block — score ' +
      String.valueOf(pressureScore.setScale(1)) +
      ' (threshold ' +
      String.valueOf(
        OutreachQueuePolicy.config().pressureBlockThreshold.setScale(1)
      ) +
      ')';
  }

  /**
   * Default: one outreach per patient per week after a contact event.
   * Override_Weekly_Queue_Cooldown__c OR pressure-gate bypass → 1-day floor.
   */
  @TestVisible
  static void applyWeeklyQueueCooldown(
    Outreach_Episode__c e,
    Boolean overrideCooldown,
    Datetime lastAt
  ) {
    if (e == null)
      return;
    if (
      e.Status__c == 'Completed' ||
      e.Status__c == 'Cancelled' ||
      e.Status__c == 'Snoozed'
    )
      return;
    if (lastAt == null)
      return;
    Integer coolDays = overrideCooldown == true
      ? OVERRIDE_MIN_RESURFACE_DAYS
      : WEEKLY_QUEUE_COOLDOWN_DAYS;
    Date eligible = lastAt.date().addDays(coolDays);
    if (eligible <= Date.today())
      return;
    e.Status__c = 'Snoozed';
    e.Next_Action_Date__c = eligible;
    e.Next_Action__c =
      (overrideCooldown == true
        ? 'Override cooldown — next eligible '
        : 'Weekly cooldown — next eligible ') + String.valueOf(eligible);
  }

  private static Set<String> weeklyOverrideRuleIds(
    Map<Id, List<Patient_Need__c>> byPatient
  ) {
    Set<String> allRuleIds = new Set<String>();
    for (List<Patient_Need__c> needs : byPatient.values())
      for (Patient_Need__c n : needs)
        if (String.isNotBlank(n.Rule_Id__c))
          allRuleIds.add(n.Rule_Id__c);
    Set<String> out = new Set<String>();
    if (allRuleIds.isEmpty())
      return out;
    for (Outreach_Rule__mdt rule : [
      SELECT Rule_Id__c
      FROM Outreach_Rule__mdt
      WHERE
        Rule_Id__c IN :allRuleIds
        AND Override_Weekly_Queue_Cooldown__c = TRUE
    ])
      out.add(rule.Rule_Id__c);
    return out;
  }

  private static Map<Id, Datetime> lastContactByPatient(Set<Id> patientIds) {
    Map<Id, Datetime> out = new Map<Id, Datetime>();
    if (patientIds == null || patientIds.isEmpty())
      return out;
    for (AggregateResult row : [
      SELECT Patient__c patientId, MAX(Event_At__c) lastAt
      FROM Outreach_Event__c
      WHERE
        Patient__c IN :patientIds
        AND Event_Type__c IN :CONTACT_EVENT_TYPES
      GROUP BY Patient__c
    ]) {
      out.put((Id) row.get('patientId'), (Datetime) row.get('lastAt'));
    }
    return out;
  }


  private static Map<String, Set<String>> bypassPressureRulesByPatient(
    Map<Id, List<Patient_Need__c>> byPatient
  ) {
    Map<String, Set<String>> out = new Map<String, Set<String>>();
    Set<String> allRuleIds = new Set<String>();
    for (List<Patient_Need__c> needs : byPatient.values())
      for (Patient_Need__c n : needs)
        if (String.isNotBlank(n.Rule_Id__c))
          allRuleIds.add(n.Rule_Id__c);
    if (allRuleIds.isEmpty())
      return out;
    Set<String> bypassRuleIds = new Set<String>();
    for (Outreach_Rule__mdt rule : [
      SELECT Rule_Id__c
      FROM Outreach_Rule__mdt
      WHERE Rule_Id__c IN :allRuleIds AND Bypass_Pressure_Gate__c = TRUE
    ])
      bypassRuleIds.add(rule.Rule_Id__c);
    if (bypassRuleIds.isEmpty())
      return out;
    for (Id patientId : byPatient.keySet()) {
      Set<String> hits = new Set<String>();
      for (Patient_Need__c n : byPatient.get(patientId))
        if (bypassRuleIds.contains(n.Rule_Id__c))
          hits.add(n.Rule_Id__c);
      if (!hits.isEmpty())
        out.put(String.valueOf(patientId), hits);
    }
    return out;
  }

  public class OutreachPlannerException extends Exception {
  }
  @TestVisible
  static Integer priorityRank(String p) {
    return p == 'STAT' ? 0 : p == 'Urgent' ? 1 : 2;
  }
  private static Decimal value(Decimal d) {
    return d == null ? 0 : d;
  }
  private static String episodeKey(Id id) {
    return String.valueOf(id) + ':ACTIVE';
  }
}
