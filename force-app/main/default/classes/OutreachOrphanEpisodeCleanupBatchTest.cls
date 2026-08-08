@IsTest
private class OutreachOrphanEpisodeCleanupBatchTest {
  private static Account patient(String suffix) {
    Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
      .get('PersonAccount')
      .getRecordTypeId();
    Account a = new Account(
      LastName = 'Orphan ' + suffix,
      RecordTypeId = rt,
      SourceSystemIdentifier = 'ORPH-' + suffix
    );
    insert a;
    return a;
  }

  @IsTest
  static void batchCompletesEpisodesWithoutActiveNeeds() {
    Account orphan = patient('a');
    Account kept = patient('b');
    insert new Patient_Need__c(
      Engine_Key__c = kept.Id + ':NO_NEXT_FOLLOWUP:1',
      Patient__c = kept.Id,
      Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Pending',
      Priority__c = 'Urgent',
      Points__c = 40,
      Next_Action_Date__c = Date.today()
    );
    Outreach_Episode__c keptEp = OutreachEpisodePlanner.plan(
      new Set<Id>{ kept.Id }
    )[0];
    Id queueId = [
      SELECT Id
      FROM Group
      WHERE Type = 'Queue' AND DeveloperName = 'PES_Outreach'
      LIMIT 1
    ]
    .Id;
    Outreach_Episode__c orphanEp = new Outreach_Episode__c(
      Engine_Key__c = String.valueOf(orphan.Id) + ':ACTIVE',
      Patient__c = orphan.Id,
      Status__c = 'Unclaimed',
      Shadow__c = false,
      Priority__c = 'Urgent',
      Primary_Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Points__c = 40,
      Next_Action_Date__c = Date.today(),
      OwnerId = queueId
    );
    insert orphanEp;

    Test.startTest();
    Database.executeBatch(new OutreachOrphanEpisodeCleanupBatch(), 200);
    Test.stopTest();

    Outreach_Episode__c orphanAfter = [
      SELECT Status__c, Next_Action__c
      FROM Outreach_Episode__c
      WHERE Id = :orphanEp.Id
    ];
    Outreach_Episode__c keptAfter = [
      SELECT Status__c
      FROM Outreach_Episode__c
      WHERE Id = :keptEp.Id
    ];
    Assert.areEqual(
      'Completed',
      orphanAfter.Status__c,
      'Orphan episode should be completed'
    );
    Assert.areEqual(
      'Unclaimed',
      keptAfter.Status__c,
      'Episode with active need must stay open'
    );
  }

  @IsTest
  static void runEnqueuesBatch() {
    Test.startTest();
    Id jobId = OutreachOrphanEpisodeCleanupBatch.run();
    Test.stopTest();
    Assert.isNotNull(jobId, 'run() should return a job Id');
  }
}
