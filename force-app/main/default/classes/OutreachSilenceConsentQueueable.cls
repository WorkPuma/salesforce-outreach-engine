/**
 * Async OptOut of preference topics when a Care Item is silenced (DEV-4684).
 * Keeps silenceNeed under SOQL governor limits.
 */
public without sharing class OutreachSilenceConsentQueueable implements Queueable {
  private final Id accountId;
  private final String topicKey;

  public OutreachSilenceConsentQueueable(Id accountId, String topicKey) {
    this.accountId = accountId;
    this.topicKey = topicKey;
  }

  public void execute(QueueableContext qc) {
    if (accountId == null || String.isBlank(topicKey)) {
      return;
    }
    try {
      OutreachConsentGate.optOutTopicForSilence(accountId, topicKey);
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'OutreachSilenceConsentQueueable failed: ' + e.getMessage()
      );
    }
  }
}
