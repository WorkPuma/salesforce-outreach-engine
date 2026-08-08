/**
 * Schedules OutreachEvidenceReconcileBatch daily after ~9am Central.
 * Cron is UTC: 14:00 UTC ~= 9am CDT (Central Daylight).
 */
public class OutreachEvidenceReconcileScheduler implements Schedulable {
  public static final String JOB_NAME = 'Outreach Evidence Reconcile Daily';
  // 9:00 AM CDT (UTC-5) => 14:00 UTC. During CST (UTC-6) this is 8:00 AM local.
  public static final String CRON_UTC = '0 0 14 * * ?';

  private Integer batchSize;

  public OutreachEvidenceReconcileScheduler() {
    this(50);
  }

  public OutreachEvidenceReconcileScheduler(Integer batchSize) {
    this.batchSize = batchSize == null || batchSize < 1 ? 50 : batchSize;
  }

  public void execute(SchedulableContext sc) {
    Database.executeBatch(new OutreachEvidenceReconcileBatch(), this.batchSize);
  }

  public static String scheduleDaily() {
    List<CronTrigger> existing = [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name = :JOB_NAME AND State != 'DELETED'
    ];
    for (CronTrigger job : existing)
      System.abortJob(job.Id);
    return System.schedule(
      JOB_NAME,
      CRON_UTC,
      new OutreachEvidenceReconcileScheduler()
    );
  }
}
