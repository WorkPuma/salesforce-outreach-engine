/**
 * Daily appointment-first evidence reconcile for outreach outcomes that require
 * appointment proof (CMDT Requires_Evidence / Appointment Scheduled).
 *
 * Policy: trust the agent outcome, then async match; reopen (hidden Reopened)
 * when no qualifying appointment is found after grace.
 */
public without sharing class OutreachEvidenceReconcileBatch implements Database.Batchable<SObject> {
  @TestVisible
  static Integer lookbackDays = 14;
  @TestVisible
  static Integer graceHours = 48;
  @TestVisible
  static Integer matchWindowDaysAfter = 14;

  public Database.QueryLocator start(Database.BatchableContext context) {
    Datetime sinceWhen = System.now().addDays(-lookbackDays);
    return Database.getQueryLocator(
      [
        SELECT
          Id,
          Patient__c,
          Need__c,
          Episode__c,
          Rule_Id__c,
          Event_Type__c,
          Outcome__c,
          Event_At__c,
          Actor__c
        FROM Outreach_Event__c
        WHERE
          Event_At__c >= :sinceWhen
          AND (
            Event_Type__c = 'Appointment Scheduled'
            OR Outcome__c = 'Appointment Scheduled'
            OR Outcome__c = 'Patient Scheduled'
          )
        ORDER BY Event_At__c ASC
      ]
    );
  }

  public void execute(Database.BatchableContext context, List<SObject> scope) {
    List<Outreach_Event__c> events = (List<Outreach_Event__c>) scope;
    if (events.isEmpty())
      return;

    Set<Id> eventIds = new Set<Id>();
    Set<Id> patientIds = new Set<Id>();
    Set<Id> needIds = new Set<Id>();
    Set<String> ruleIds = new Set<String>();
    for (Outreach_Event__c e : events) {
      eventIds.add(e.Id);
      if (e.Patient__c != null)
        patientIds.add(e.Patient__c);
      if (e.Need__c != null)
        needIds.add(e.Need__c);
      if (String.isBlank(e.Rule_Id__c) == false)
        ruleIds.add(e.Rule_Id__c);
    }

    Map<Id, Outreach_Evidence_Link__c> linkByEvent = loadLinks(eventIds);
    Map<String, Set<String>> requiredTypesByRule = loadRequiredTypes(ruleIds);
    Map<Id, Patient_Need__c> needsById = loadNeeds(needIds);
    Map<Id, List<Appointment__c>> apptsByPatient = loadAppointments(
      patientIds,
      events
    );

    List<Outreach_Evidence_Link__c> upserts = new List<Outreach_Evidence_Link__c>();
    List<Patient_Need__c> reopenNeeds = new List<Patient_Need__c>();
    List<OutreachEventService.EventRequest> reopenEvents = new List<OutreachEventService.EventRequest>();
    Datetime graceCutoff = System.now().addHours(-graceHours);

    for (Outreach_Event__c e : events) {
      Outreach_Evidence_Link__c existing = linkByEvent.get(e.Id);
      if (existing != null && existing.Reconcile_Status__c == 'Matched')
        continue;

      String ruleId = e.Rule_Id__c;
      if (String.isBlank(ruleId) && e.Need__c != null && needsById.containsKey(e.Need__c))
        ruleId = needsById.get(e.Need__c).Rule_Id__c;
      Set<String> requiredTypes = String.isBlank(ruleId)
        ? null
        : requiredTypesByRule.get(ruleId);

      Appointment__c match = findMatch(
        e,
        apptsByPatient.get(e.Patient__c),
        requiredTypes
      );
      String engineKey = engineKeyFor(e.Id);

      if (match != null) {
        Outreach_Evidence_Link__c link = existing != null
          ? existing
          : new Outreach_Evidence_Link__c();
        link.Engine_Key__c = engineKey;
        link.Outreach_Event__c = e.Id;
        link.Patient__c = e.Patient__c;
        link.Need__c = e.Need__c;
        link.Appointment__c = match.Id;
        link.Match_Kind__c = 'Appointment';
        link.Match_Method__c = 'Patient+Type+TimeWindow';
        link.Match_Confidence__c = 0.9;
        link.Agent_Match__c = 'Unknown';
        link.Reconcile_Status__c = 'Matched';
        upserts.add(link);
        continue;
      }

      Outreach_Evidence_Link__c pending = existing != null
        ? existing
        : new Outreach_Evidence_Link__c();
      pending.Engine_Key__c = engineKey;
      pending.Outreach_Event__c = e.Id;
      pending.Patient__c = e.Patient__c;
      pending.Need__c = e.Need__c;
      pending.Match_Kind__c = 'Appointment';
      pending.Match_Method__c = 'Patient+Type+TimeWindow';
      pending.Match_Confidence__c = 0;
      pending.Agent_Match__c = 'Unknown';
      pending.Reconcile_Status__c = 'Unmatched';

      Patient_Need__c needRow = e.Need__c == null ? null : needsById.get(e.Need__c);
      if (
        needRow != null &&
        needRow.State__c == 'Resolved' &&
        e.Event_At__c != null &&
        e.Event_At__c <= graceCutoff
      ) {
        reopenNeeds.add(
          new Patient_Need__c(Id = e.Need__c, State__c = 'Pending')
        );
        OutreachEventService.EventRequest r = new OutreachEventService.EventRequest();
        r.patientId = e.Patient__c;
        r.episodeId = e.Episode__c;
        r.needId = e.Need__c;
        r.ruleId = ruleId;
        r.eventType = 'Reopened';
        r.outcome = 'Evidence Missing';
        r.detail = 'No matching appointment found for Appointment Scheduled outcome';
        r.shadow = true;
        r.idempotencyKey = e.Id + ':Reopened:EvidenceMissing';
        reopenEvents.add(r);
        pending.Reconcile_Status__c = 'Reopened';
      }
      upserts.add(pending);
    }

    if (!upserts.isEmpty())
      upsert upserts Engine_Key__c;
    if (!reopenNeeds.isEmpty())
      update reopenNeeds;
    if (!reopenEvents.isEmpty())
      OutreachEventService.append(reopenEvents);
  }

  public void finish(Database.BatchableContext context) {
  }

  @TestVisible
  static String engineKeyFor(Id eventId) {
    return 'EVL:' + String.valueOf(eventId) + ':Appointment';
  }

  private static Map<Id, Outreach_Evidence_Link__c> loadLinks(Set<Id> eventIds) {
    Map<Id, Outreach_Evidence_Link__c> out = new Map<Id, Outreach_Evidence_Link__c>();
    for (Outreach_Evidence_Link__c row : [
      SELECT
        Id,
        Engine_Key__c,
        Outreach_Event__c,
        Patient__c,
        Need__c,
        Appointment__c,
        Reconcile_Status__c,
        Match_Kind__c
      FROM Outreach_Evidence_Link__c
      WHERE
        Outreach_Event__c IN :eventIds
        AND Match_Kind__c = 'Appointment'
    ]) {
      out.put(row.Outreach_Event__c, row);
    }
    return out;
  }

  private static Map<String, Set<String>> loadRequiredTypes(Set<String> ruleIds) {
    Map<String, Set<String>> out = new Map<String, Set<String>>();
    if (ruleIds == null || ruleIds.isEmpty())
      return out;
    for (Outreach_Rule__mdt r : [
      SELECT Rule_Id__c, Required_Appointment_Types__c
      FROM Outreach_Rule__mdt
      WHERE Rule_Id__c IN :ruleIds
    ]) {
      Set<String> types = splitTypes(r.Required_Appointment_Types__c);
      if (!types.isEmpty())
        out.put(r.Rule_Id__c, types);
    }
    return out;
  }

  private static Map<Id, Patient_Need__c> loadNeeds(Set<Id> needIds) {
    Map<Id, Patient_Need__c> out = new Map<Id, Patient_Need__c>();
    if (needIds == null || needIds.isEmpty())
      return out;
    for (Patient_Need__c n : [
      SELECT Id, Rule_Id__c, State__c
      FROM Patient_Need__c
      WHERE Id IN :needIds
    ]) {
      out.put(n.Id, n);
    }
    return out;
  }

  private static Map<Id, List<Appointment__c>> loadAppointments(
    Set<Id> patientIds,
    List<Outreach_Event__c> events
  ) {
    Map<Id, List<Appointment__c>> out = new Map<Id, List<Appointment__c>>();
    if (patientIds == null || patientIds.isEmpty())
      return out;
    Datetime minAt = System.now().addDays(-lookbackDays - 1);
    Datetime maxAt = System.now().addDays(matchWindowDaysAfter);
    for (Outreach_Event__c e : events) {
      if (e.Event_At__c == null)
        continue;
      Datetime lo = e.Event_At__c.addDays(-1);
      Datetime hi = e.Event_At__c.addDays(matchWindowDaysAfter);
      if (lo < minAt)
        minAt = lo;
      if (hi > maxAt)
        maxAt = hi;
    }
    Set<String> okStatus = new Set<String>();
    okStatus.addAll(AppointmentStatuses.ACTIVE);
    okStatus.addAll(AppointmentStatuses.COMPLETED);
    for (Appointment__c a : [
      SELECT
        Id,
        Patient__c,
        Type__c,
        Status__c,
        Start_Date_Time__c,
        Scheduled_By__c
      FROM Appointment__c
      WHERE
        Patient__c IN :patientIds
        AND Start_Date_Time__c >= :minAt
        AND Start_Date_Time__c <= :maxAt
        AND Status__c IN :okStatus
    ]) {
      if (!out.containsKey(a.Patient__c))
        out.put(a.Patient__c, new List<Appointment__c>());
      out.get(a.Patient__c).add(a);
    }
    return out;
  }

  @TestVisible
  static Appointment__c findMatch(
    Outreach_Event__c e,
    List<Appointment__c> appts,
    Set<String> requiredTypes
  ) {
    if (e == null || appts == null || appts.isEmpty() || e.Event_At__c == null)
      return null;
    Datetime lo = e.Event_At__c.addDays(-1);
    Datetime hi = e.Event_At__c.addDays(matchWindowDaysAfter);
    Appointment__c best = null;
    Long bestDelta = null;
    for (Appointment__c a : appts) {
      if (a.Start_Date_Time__c == null)
        continue;
      if (a.Start_Date_Time__c < lo || a.Start_Date_Time__c > hi)
        continue;
      if (requiredTypes != null && !requiredTypes.isEmpty()) {
        String t = a.Type__c == null ? '' : a.Type__c.trim().toLowerCase();
        Boolean typeOk = false;
        for (String req : requiredTypes) {
          if (req != null && req.trim().toLowerCase() == t) {
            typeOk = true;
            break;
          }
        }
        if (!typeOk)
          continue;
      }
      Long delta = Math.abs(
        a.Start_Date_Time__c.getTime() - e.Event_At__c.getTime()
      );
      if (best == null || delta < bestDelta) {
        best = a;
        bestDelta = delta;
      }
    }
    return best;
  }

  @TestVisible
  static Set<String> splitTypes(String raw) {
    Set<String> out = new Set<String>();
    if (String.isBlank(raw))
      return out;
    for (String part : raw.split('[;,]')) {
      if (String.isNotBlank(part))
        out.add(part.trim());
    }
    return out;
  }
}
