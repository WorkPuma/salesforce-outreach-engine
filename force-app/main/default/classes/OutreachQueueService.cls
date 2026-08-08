/**
 * Outreach Workbench "The Queue" dashboard API.
 * Parent care-item KPIs; recently viewed/worked; unclaimed list. Opens Account, not Case.
 * Unclaimed rows require at least one active Patient_Need__c (orphan episodes excluded).
 */
public with sharing class OutreachQueueService {
  private static final Integer DEFAULT_LIMIT = 40;
  private static final Integer KPI_NEED_LIMIT = 5000;
  private static final Set<String> WORK_EVENT_TYPES = new Set<String>{
    'Attempt Made',
    'Connected',
    'Left Voicemail',
    'No Answer',
    'Wrong Number',
    'Outcome Recorded',
    'Snoozed',
    'Appointment Scheduled'
  };

  private static Id cachedPesQueueId;
  private static Set<String> cachedAllowedRuleIds;
  private static Boolean cachedAllowedLoaded = false;

  public class KpiCard {
    @AuraEnabled
    public String key;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public Integer patientCount;
  }
  public class CareGap {
    @AuraEnabled
    public String key;
    @AuraEnabled
    public String label;
  }
  public class PriorityLoad {
    @AuraEnabled
    public Integer urgentCount;
    @AuraEnabled
    public Integer routineCount;
    @AuraEnabled
    public Integer statCount;
    @AuraEnabled
    public Integer totalCount;
    @AuraEnabled
    public Integer percentUrgent;
  }
  public class QueueRow {
    @AuraEnabled
    public Id episodeId;
    @AuraEnabled
    public Id accountId;
    @AuraEnabled
    public String patientName;
    @AuraEnabled
    public String accountUrl;
    @AuraEnabled
    public String priority;
    @AuraEnabled
    public Decimal points;
    @AuraEnabled
    public Date dueDate;
    @AuraEnabled
    public String ownerName;
    @AuraEnabled
    public String clinic;
    @AuraEnabled
    public String needsSummary;
    @AuraEnabled
    public List<CareGap> careGaps;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public Datetime lastActivityAt;
    @AuraEnabled
    public String actorName;
  }
  public class Dashboard {
    @AuraEnabled
    public List<KpiCard> kpis;
    @AuraEnabled
    public PriorityLoad priorityLoad;
    @AuraEnabled
    public List<QueueRow> recentlyViewed;
    @AuraEnabled
    public List<QueueRow> recentlyWorked;
    @AuraEnabled
    public List<QueueRow> unclaimed;
    @AuraEnabled
    public Boolean canSupervise;
    @AuraEnabled
    public Boolean supervisorMode;
    @AuraEnabled
    public Boolean omniEnabled;
  }

  /**
   * @param supervisorMode When true and permitted, include all PES queue work
   * @param priorityFilter STAT | Urgent | Routine | All
   * @param rowLimit Max rows per list section (1-100)
   * @return Dashboard payload for the Outreach Workbench LWC
   */
  @AuraEnabled(cacheable=false)
  public static Dashboard getQueueDashboard(
    Boolean supervisorMode,
    String priorityFilter,
    Integer rowLimit
  ) {
    Boolean canSupervise = FeatureManagement.checkPermission(
      'Outreach_Workbench_Supervisor'
    );
    Boolean useSupervisor = canSupervise == true && supervisorMode == true;
    Integer size = rowLimit == null || rowLimit < 1 || rowLimit > 100
      ? DEFAULT_LIMIT
      : rowLimit;

    Set<String> allowedRuleIds = resolveAllowedRuleIds(useSupervisor);

    Dashboard d = new Dashboard();
    d.canSupervise = canSupervise;
    d.supervisorMode = useSupervisor;
    d.omniEnabled = OutreachOmniRoutingService.isEnabled();
    d.kpis = buildKpis();
    d.priorityLoad = buildPriorityLoad(priorityFilter, useSupervisor, allowedRuleIds);
    // recentlyViewed is unused by outreachWorkbench LWC — skip to save SOQL/CPU.
    d.recentlyViewed = new List<QueueRow>();
    d.recentlyWorked = buildRecentFromEvents(
      WORK_EVENT_TYPES,
      useSupervisor,
      priorityFilter,
      size
    );
    d.unclaimed = buildUnclaimed(priorityFilter, size, useSupervisor, allowedRuleIds);
    return d;
  }

  private static Id pesQueueId() {
    if (cachedPesQueueId != null)
      return cachedPesQueueId;
    cachedPesQueueId = [
      SELECT Id
      FROM Group
      WHERE Type = 'Queue' AND DeveloperName = 'PES_Outreach'
      LIMIT 1
    ]
    .Id;
    return cachedPesQueueId;
  }

  private static Set<String> resolveAllowedRuleIds(Boolean supervisor) {
    if (supervisor == true)
      return null;
    if (cachedAllowedLoaded)
      return cachedAllowedRuleIds;
    cachedAllowedRuleIds = OutreachAudienceSkillService.allowedRuleIdsForCurrentUser();
    cachedAllowedLoaded = true;
    return cachedAllowedRuleIds;
  }

  private static List<KpiCard> buildKpis() {
    Map<String, Set<Id>> patientsByKey = new Map<String, Set<Id>>();
    for (String k : OutreachCareItemTaxonomy.PARENT_KEYS)
      patientsByKey.put(k, new Set<Id>());

    List<Patient_Need__c> needs = [
      SELECT Id, Patient__c, Rule_Id__c, Need_Type__c, State__c, Shadow__c
      FROM Patient_Need__c
      WHERE
        State__c IN :OutreachCareItemTaxonomy.ACTIVE_NEED_STATES
        AND Shadow__c = FALSE
        AND Patient__c != NULL
      LIMIT :KPI_NEED_LIMIT
    ];
    Map<Id, List<Patient_Need__c>> byPatient = new Map<Id, List<Patient_Need__c>>();
    for (Patient_Need__c n : needs) {
      if (!byPatient.containsKey(n.Patient__c))
        byPatient.put(n.Patient__c, new List<Patient_Need__c>());
      byPatient.get(n.Patient__c).add(n);
    }
    for (Id pid : byPatient.keySet()) {
      for (
        String key : OutreachCareItemTaxonomy.parentKeysForNeeds(
          byPatient.get(pid)
        )
      ) {
        if (patientsByKey.containsKey(key))
          patientsByKey.get(key).add(pid);
      }
    }

    List<KpiCard> cards = new List<KpiCard>();
    for (
      String key : new List<String>{
        'OFF_CADENCE',
        'NO_NEXT',
        'AWV',
        'UNENGAGED'
      }
    ) {
      KpiCard c = new KpiCard();
      c.key = key;
      c.label = OutreachCareItemTaxonomy.parentLabel(key, key);
      c.patientCount = patientsByKey.get(key).size();
      cards.add(c);
    }
    return cards;
  }

  private static List<QueueRow> buildUnclaimed(
    String priorityFilter,
    Integer size,
    Boolean supervisor,
    Set<String> allowedRuleIds
  ) {
    if (!supervisor && (allowedRuleIds == null || allowedRuleIds.isEmpty()))
      return new List<QueueRow>();
    Id queueId = pesQueueId();
    Set<String> activeStates = OutreachCareItemTaxonomy.ACTIVE_NEED_STATES;
    String q =
      'SELECT Id, Patient__c, Patient__r.Name, Patient__r.Preferred_Clinic__c, ' +
      'Patient__r.Primary_Clinic__r.Name, Priority__c, Primary_Rule_Id__c, Points__c, Next_Action_Date__c, ' +
      'Status__c, OwnerId, Owner.Name ' +
      'FROM Outreach_Episode__c WHERE Status__c = \'Unclaimed\' AND Shadow__c = FALSE AND OwnerId = :queueId ' +
      'AND Patient__c IN (SELECT Patient__c FROM Patient_Need__c WHERE State__c IN :activeStates AND Shadow__c = FALSE)';
    if (String.isNotBlank(priorityFilter) && priorityFilter != 'All')
      q += ' AND Priority__c = :priorityFilter';
    if (!supervisor)
      q += ' AND Primary_Rule_Id__c IN :allowedRuleIds';
    q += ' ORDER BY Routing_Priority__c ASC NULLS LAST, Id ASC LIMIT :size';
    List<Outreach_Episode__c> eps = Database.query(q);
    return toRows(eps, new Map<Id, Outreach_Event__c>());
  }

  private static List<QueueRow> buildRecentFromEvents(
    Set<String> eventTypes,
    Boolean supervisor,
    String priorityFilter,
    Integer size
  ) {
    Id uid = UserInfo.getUserId();
    String soql =
      'SELECT Id, Episode__c, Actor__c, Actor__r.Name, Event_Type__c, Event_At__c ' +
      'FROM Outreach_Event__c WHERE Event_Type__c IN :eventTypes AND Episode__c != null ';
    if (!supervisor)
      soql += 'AND Actor__c = :uid ';
    soql += 'ORDER BY Event_At__c DESC LIMIT 200';
    List<Outreach_Event__c> events = Database.query(soql);

    Map<Id, Outreach_Event__c> latestByEpisode = new Map<Id, Outreach_Event__c>();
    for (Outreach_Event__c e : events) {
      if (!latestByEpisode.containsKey(e.Episode__c))
        latestByEpisode.put(e.Episode__c, e);
    }
    if (latestByEpisode.isEmpty())
      return new List<QueueRow>();

    String eq =
      'SELECT Id, Patient__c, Patient__r.Name, Patient__r.Preferred_Clinic__c, ' +
      'Patient__r.Primary_Clinic__r.Name, Priority__c, Primary_Rule_Id__c, Points__c, Next_Action_Date__c, ' +
      'Status__c, OwnerId, Owner.Name ' +
      'FROM Outreach_Episode__c WHERE Id IN :epidKeys AND Shadow__c = FALSE';
    if (String.isNotBlank(priorityFilter) && priorityFilter != 'All')
      eq += ' AND Priority__c = :priorityFilter';
    Set<Id> epidKeys = latestByEpisode.keySet();
    Map<Id, Outreach_Episode__c> eps = new Map<Id, Outreach_Episode__c>(
      (List<Outreach_Episode__c>) Database.query(eq)
    );

    List<Outreach_Episode__c> ordered = new List<Outreach_Episode__c>();
    Map<Id, Outreach_Event__c> eventByEpisode = new Map<Id, Outreach_Event__c>();
    Integer n = 0;
    for (Id epid : latestByEpisode.keySet()) {
      if (n >= size)
        break;
      Outreach_Episode__c ep = eps.get(epid);
      if (ep == null)
        continue;
      ordered.add(ep);
      eventByEpisode.put(epid, latestByEpisode.get(epid));
      n++;
    }
    return toRows(ordered, eventByEpisode);
  }

  private static List<QueueRow> toRows(
    List<Outreach_Episode__c> eps,
    Map<Id, Outreach_Event__c> eventByEpisode
  ) {
    Set<Id> patientIds = new Set<Id>();
    for (Outreach_Episode__c ep : eps) {
      if (ep.Patient__c != null)
        patientIds.add(ep.Patient__c);
    }
    Map<Id, List<CareGap>> careGapsByPatient = careGapsByPatient(patientIds);
    List<QueueRow> rows = new List<QueueRow>();
    for (Outreach_Episode__c ep : eps) {
      QueueRow r = new QueueRow();
      r.episodeId = ep.Id;
      r.accountId = ep.Patient__c;
      r.patientName = ep.Patient__r != null ? ep.Patient__r.Name : null;
      r.accountUrl = ep.Patient__c != null
        ? '/lightning/r/Account/' + ep.Patient__c + '/view'
        : null;
      r.points = ep.Points__c;
      r.dueDate = ep.Next_Action_Date__c;
      r.ownerName = ep.Owner != null ? ep.Owner.Name : null;
      if (ep.Patient__r != null) {
        r.clinic = ep.Patient__r.Primary_Clinic__r != null
          ? ep.Patient__r.Primary_Clinic__r.Name
          : ep.Patient__r.Preferred_Clinic__c;
      }
      List<CareGap> gaps = careGapsByPatient.containsKey(ep.Patient__c)
        ? careGapsByPatient.get(ep.Patient__c)
        : new List<CareGap>();
      if (gaps.isEmpty())
        gaps = careGapsFromPrimaryRule(ep.Primary_Rule_Id__c);
      r.careGaps = gaps;
      List<String> labels = new List<String>();
      for (CareGap g : gaps)
        labels.add(g.label);
      r.needsSummary = String.join(labels, ' · ');
      r.priority = ep.Priority__c;
      r.status = ep.Status__c;
      Outreach_Event__c ev = eventByEpisode == null
        ? null
        : eventByEpisode.get(ep.Id);
      if (ev != null) {
        r.lastActivityAt = ev.Event_At__c;
        r.actorName = ev.Actor__r != null ? ev.Actor__r.Name : null;
      }
      rows.add(r);
    }
    return rows;
  }

  private static List<CareGap> careGapsFromPrimaryRule(String ruleId) {
    List<CareGap> gaps = new List<CareGap>();
    if (String.isBlank(ruleId))
      return gaps;
    String key = OutreachCareItemTaxonomy.parentKey(ruleId, null, null);
    if (!OutreachCareItemTaxonomy.PARENT_KEYS.contains(key))
      return gaps;
    CareGap g = new CareGap();
    g.key = key;
    g.label = OutreachCareItemTaxonomy.parentLabel(key, key);
    gaps.add(g);
    return gaps;
  }

  private static Map<Id, List<CareGap>> careGapsByPatient(Set<Id> patientIds) {
    Map<Id, List<CareGap>> out = new Map<Id, List<CareGap>>();
    if (patientIds == null || patientIds.isEmpty())
      return out;
    List<Patient_Need__c> needs = [
      SELECT Id, Patient__c, Rule_Id__c, Need_Type__c, State__c, Shadow__c
      FROM Patient_Need__c
      WHERE
        Patient__c IN :patientIds
        AND State__c IN :OutreachCareItemTaxonomy.ACTIVE_NEED_STATES
        AND Shadow__c = FALSE
    ];
    Map<Id, List<Patient_Need__c>> byP = new Map<Id, List<Patient_Need__c>>();
    for (Patient_Need__c n : needs) {
      if (!byP.containsKey(n.Patient__c))
        byP.put(n.Patient__c, new List<Patient_Need__c>());
      byP.get(n.Patient__c).add(n);
    }
    for (Id pid : byP.keySet()) {
      List<CareGap> gaps = new List<CareGap>();
      for (
        String key : OutreachCareItemTaxonomy.parentKeysForNeeds(byP.get(pid))
      ) {
        CareGap g = new CareGap();
        g.key = key;
        g.label = OutreachCareItemTaxonomy.parentLabel(key, key);
        gaps.add(g);
      }
      out.put(pid, gaps);
    }
    return out;
  }

  private static PriorityLoad buildPriorityLoad(
    String priorityFilter,
    Boolean supervisor,
    Set<String> allowedRuleIds
  ) {
    PriorityLoad load = new PriorityLoad();
    load.urgentCount = 0;
    load.routineCount = 0;
    load.statCount = 0;
    load.totalCount = 0;
    load.percentUrgent = 0;
    if (!supervisor && (allowedRuleIds == null || allowedRuleIds.isEmpty()))
      return load;
    Id queueId = pesQueueId();
    Set<String> activeStates = OutreachCareItemTaxonomy.ACTIVE_NEED_STATES;
    String q =
      'SELECT Priority__c priority, COUNT(Id) cnt FROM Outreach_Episode__c ' +
      'WHERE Status__c = \'Unclaimed\' AND Shadow__c = FALSE AND OwnerId = :queueId ' +
      'AND Patient__c IN (SELECT Patient__c FROM Patient_Need__c WHERE State__c IN :activeStates AND Shadow__c = FALSE)';
    if (String.isNotBlank(priorityFilter) && priorityFilter != 'All')
      q += ' AND Priority__c = :priorityFilter';
    if (!supervisor)
      q += ' AND Primary_Rule_Id__c IN :allowedRuleIds';
    q += ' GROUP BY Priority__c';
    for (AggregateResult ar : Database.query(q)) {
      String pri = (String) ar.get('priority');
      Integer cnt = Integer.valueOf(ar.get('cnt'));
      load.totalCount += cnt;
      if (pri == 'STAT')
        load.statCount += cnt;
      else if (pri == 'Urgent')
        load.urgentCount += cnt;
      else
        load.routineCount += cnt;
    }
    Integer actionable = load.urgentCount + load.routineCount + load.statCount;
    if (actionable > 0)
      load.percentUrgent = Integer.valueOf(
        Math.round(
          (Decimal.valueOf(load.urgentCount + load.statCount) /
            Decimal.valueOf(actionable)) * 100
        )
      );
    return load;
  }
}
