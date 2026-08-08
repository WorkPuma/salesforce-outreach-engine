@IsTest
private class OutreachQueueServiceTest {
  private static Account patient(String suffix) {
    Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
      .get('PersonAccount')
      .getRecordTypeId();
    Account a = new Account(
      LastName = 'Queue ' + suffix,
      RecordTypeId = rt,
      SourceSystemIdentifier = 'Q-' + suffix
    );
    insert a;
    return a;
  }

  @IsTest
  static void dashboardReturnsUnclaimedAndKpis() {
    Account a = patient('dash');
    insert new Patient_Need__c(
      Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
      Patient__c = a.Id,
      Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Pending',
      Priority__c = 'Urgent',
      Points__c = 50,
      Next_Action_Date__c = Date.today()
    );
    Outreach_Episode__c ep = OutreachEpisodePlanner.plan(new Set<Id>{ a.Id })[0];
    System.assertEquals('Unclaimed', ep.Status__c);

    Test.startTest();
    OutreachQueueService.Dashboard d = OutreachQueueService.getQueueDashboard(
      false,
      'All',
      20
    );
    Test.stopTest();

    System.assertNotEquals(null, d);
    System.assertNotEquals(null, d.kpis);
    System.assert(d.kpis.size() >= 3);
    System.assertNotEquals(null, d.priorityLoad);
    System.assert(d.priorityLoad.totalCount >= 0);
    System.assertEquals(false, d.supervisorMode);
    System.assertEquals(
      OutreachOmniRoutingService.isEnabled(),
      d.omniEnabled,
      'Dashboard omniEnabled must mirror Omni CMDT'
    );
    Boolean found = false;
    for (OutreachQueueService.QueueRow r : d.unclaimed) {
      if (r.episodeId == ep.Id) {
        found = true;
        System.assertEquals(a.Id, r.accountId);
        System.assert(r.accountUrl != null && r.accountUrl.contains('/Account/'));
        System.assert(r.needsSummary != null);
      }
    }
    System.assert(found, 'Unclaimed episode should appear in queue');
  }

  @IsTest
  static void omniRouteIfEnabledSafeNoOp() {
    // Empty set is always a no-op whether Omni CMDT Enabled is true or false.
    Boolean enabled = OutreachOmniRoutingService.isEnabled();
    OutreachOmniRoutingService.routeIfEnabled(new Set<Id>());
    System.assertEquals(
      enabled,
      OutreachOmniRoutingService.isEnabled(),
      'routeIfEnabled must not mutate Omni enabled state'
    );
  }


  @IsTest
  static void dashboardExcludesOrphanEpisodesWithoutNeeds() {
    Account withNeed = patient('withNeed');
    Account orphan = patient('orphan');
    insert new Patient_Need__c(
      Engine_Key__c = withNeed.Id + ':NO_NEXT_FOLLOWUP:1',
      Patient__c = withNeed.Id,
      Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Pending',
      Priority__c = 'Urgent',
      Points__c = 50,
      Next_Action_Date__c = Date.today()
    );
    Outreach_Episode__c kept = OutreachEpisodePlanner.plan(
      new Set<Id>{ withNeed.Id }
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
      Points__c = 50,
      Next_Action_Date__c = Date.today(),
      OwnerId = queueId
    );
    insert orphanEp;

    Test.startTest();
    OutreachQueueService.Dashboard d = OutreachQueueService.getQueueDashboard(
      false,
      'Urgent',
      40
    );
    Test.stopTest();

    Set<Id> episodeIds = new Set<Id>();
    for (OutreachQueueService.QueueRow r : d.unclaimed)
      episodeIds.add(r.episodeId);
    Assert.isTrue(
      episodeIds.contains(kept.Id),
      'Episode with active need should remain in queue'
    );
    Assert.isFalse(
      episodeIds.contains(orphanEp.Id),
      'Orphan episode without Patient_Need__c must be excluded'
    );
    for (OutreachQueueService.QueueRow r : d.unclaimed) {
      if (r.episodeId == kept.Id) {
        Assert.isTrue(
          r.careGaps != null && !r.careGaps.isEmpty(),
          'Active-need episode should expose care gap labels'
        );
      }
    }
  }
}
