/**
 * Completes Outreach episodes that no longer have any active Patient_Need__c.
 * Keeps the PES queue aligned with care-item state and removes orphan Unclaimed rows.
 *
 * @example
 * Database.executeBatch(new OutreachOrphanEpisodeCleanupBatch(), 200);
 */
public with sharing class OutreachOrphanEpisodeCleanupBatch implements Database.Batchable<SObject>, Database.Stateful {
  private static final Integer DEFAULT_BATCH_SIZE = 200;
  private static final Set<String> OPEN_STATUSES = new Set<String>{
    'Unclaimed',
    'Claimed',
    'Snoozed'
  };

  @TestVisible
  private Integer totalScanned = 0;
  @TestVisible
  private Integer totalCompleted = 0;

  /**
   * @return Open (non-shadow) episodes that may need completion
   */
  public Database.QueryLocator start(Database.BatchableContext context) {
    return Database.getQueryLocator(
      [
        SELECT Id, Patient__c, Status__c, Engine_Key__c
        FROM Outreach_Episode__c
        WHERE Status__c IN :OPEN_STATUSES AND Shadow__c = FALSE AND Patient__c != NULL
      ]
    );
  }

  /**
   * Completes episodes whose patients have no active needs via OutreachEpisodePlanner.
   * @param context Batch context
   * @param scope Episode chunk
   */
  public void execute(Database.BatchableContext context, List<SObject> scope) {
    List<Outreach_Episode__c> episodes = (List<Outreach_Episode__c>) scope;
    if (episodes == null || episodes.isEmpty())
      return;
    totalScanned += episodes.size();

    Set<Id> patientIds = new Set<Id>();
    for (Outreach_Episode__c ep : episodes) {
      if (ep.Patient__c != null)
        patientIds.add(ep.Patient__c);
    }
    if (patientIds.isEmpty())
      return;

    Set<Id> patientsWithActiveNeeds = new Set<Id>();
    for (AggregateResult ar : [
      SELECT Patient__c patientId
      FROM Patient_Need__c
      WHERE
        Patient__c IN :patientIds
        AND State__c IN :OutreachCareItemTaxonomy.ACTIVE_NEED_STATES
        AND Shadow__c = FALSE
      GROUP BY Patient__c
    ]) {
      patientsWithActiveNeeds.add((Id) ar.get('patientId'));
    }

    Set<Id> orphanPatientIds = new Set<Id>();
    for (Id pid : patientIds) {
      if (!patientsWithActiveNeeds.contains(pid))
        orphanPatientIds.add(pid);
    }
    if (orphanPatientIds.isEmpty())
      return;

    List<Outreach_Episode__c> planned = OutreachEpisodePlanner.plan(orphanPatientIds);
    for (Outreach_Episode__c ep : planned) {
      if (ep.Status__c == 'Completed')
        totalCompleted++;
    }
  }

  /**
   * @param context Batch context
   */
  public void finish(Database.BatchableContext context) {
    // Counts retained for tests via @TestVisible fields; avoid PHI logging.
  }

  /**
   * Enqueue cleanup with the default batch size.
   * @return Async Apex job Id
   */
  public static Id run() {
    return Database.executeBatch(
      new OutreachOrphanEpisodeCleanupBatch(),
      DEFAULT_BATCH_SIZE
    );
  }

  @TestVisible
  Integer getTotalScanned() {
    return totalScanned;
  }

  @TestVisible
  Integer getTotalCompleted() {
    return totalCompleted;
  }
}
