@IsTest
private class OutreachRuntimeServiceTest {
  private static void disableRulesEngine() {
    OutreachRulesEngineClient.Settings s = new OutreachRulesEngineClient.Settings();
    s.enabled = false;
    s.projectSlug = 'patient-outreach';
    s.surfaceKey = 'outreach-surface';
    s.reactionKey = 'outreach-reaction';
    s.namedCredential = 'RulesEngine_Agent';
    s.batchSize = 20;
    OutreachRulesEngineClient.settingsOverride = s;
  }

  /** Enable RulesEngine without Named Credential callouts (empty surface / inert reaction). */
  private static void enableRulesEngineMocked() {
    OutreachRulesEngineClient.Settings s = new OutreachRulesEngineClient.Settings();
    s.enabled = true;
    s.projectSlug = 'patient-outreach';
    s.surfaceKey = 'outreach-surface';
    s.reactionKey = 'outreach-reaction';
    s.namedCredential = 'RulesEngine_Agent';
    s.batchSize = 20;
    OutreachRulesEngineClient.settingsOverride = s;
    OutreachRulesEngineClient.mockSurfaceJson = '{"result":[]}';
    OutreachRulesEngineClient.mockReactionJson =
      '{"result":{"suppressDays":0,"snoozeDays":0,"resolve":false,"reason":"test"}}';
  }

  private static Account patient(String suffix) {
    enableRulesEngineMocked();
    Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
      .get('PersonAccount')
      .getRecordTypeId();
    Account a = new Account(
      LastName = 'Outreach ' + suffix,
      RecordTypeId = rt,
      SourceSystemIdentifier = 'DEV4536-' + suffix
    );
    insert a;
    return a;
  }
  @IsTest
  static void idempotentEventsAndOverlappingNeedsPlanOneEpisode() {
    Account a = patient('plan');
    insert new List<Patient_Need__c>{
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':NO_NEXT_INITIAL:1',
        Patient__c = a.Id,
        Rule_Id__c = 'NO_NEXT_INITIAL',
        Rule_Version__c = '1',
        Need_Type__c = 'NO_NEXT',
        State__c = 'Pending',
        Priority__c = 'Routine',
        Points__c = 10,
        Next_Action_Date__c = Date.today()
      ),
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':AWV_DUE:1',
        Patient__c = a.Id,
        Rule_Id__c = 'AWV_DUE',
        Rule_Version__c = '1',
        Need_Type__c = 'AWV',
        State__c = 'Pending',
        Priority__c = 'STAT',
        Points__c = 90,
        Next_Action_Date__c = Date.today().addDays(-1)
      )
    };
    List<Outreach_Episode__c> planned = OutreachEpisodePlanner.plan(
      new Set<Id>{ a.Id }
    );
    System.assertEquals(1, planned.size());
    System.assertEquals('STAT', planned[0].Priority__c);
    System.assertEquals(90, planned[0].Points__c);
    Patient_Need__c n = [
      SELECT
        Id,
        Patient__c,
        Episode__c,
        Engine_Key__c,
        Rule_Id__c,
        Shadow__c
      FROM Patient_Need__c
      WHERE Patient__c = :a.Id
      LIMIT 1
    ];
    OutreachEventService.record(
      n,
      'Attempt Made',
      'Left Message',
      'Phone',
      'test',
      1,
      n.Engine_Key__c + ':attempt:1'
    );
    OutreachEventService.record(
      n,
      'Attempt Made',
      'Left Message',
      'Phone',
      'retry',
      1,
      n.Engine_Key__c + ':attempt:1'
    );
    String eventKey = n.Engine_Key__c + ':attempt:1';
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Outreach_Event__c
        WHERE Idempotency_Key__c = :eventKey
      ]
    );
    List<OutreachWorkbenchController.EventDTO> recent = OutreachWorkbenchController.getRecentEvents(
      a.Id,
      10
    );
    System.assertEquals(1, recent.size());
    System.assertEquals('Attempt Made', recent[0].eventType);
    Patient_Outreach_Profile__c profile = [
      SELECT Active_Need_Count__c, Episode__c
      FROM Patient_Outreach_Profile__c
      WHERE Patient__c = :a.Id
    ];
    System.assertEquals(2, profile.Active_Need_Count__c);
    System.assertEquals(planned[0].Id, profile.Episode__c);
  }
  @IsTest
  static void claimReleaseRecheckAndSuppression() {
    Account a = patient('claim');
    insert new Patient_Need__c(
      Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
      Patient__c = a.Id,
      Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Pending',
      Priority__c = 'Routine',
      Points__c = 10
    );
    Outreach_Episode__c e = OutreachEpisodePlanner.plan(new Set<Id>{ a.Id })[0];
    System.assert(OutreachWorkbenchController.claimCandidate(e.Id));
    Outreach_Episode__c held = [
      SELECT Status__c, Soft_Held_By__c, Soft_Hold_Until__c
      FROM Outreach_Episode__c
      WHERE Id = :e.Id
    ];
    System.assertEquals('Unclaimed', held.Status__c);
    System.assertEquals(UserInfo.getUserId(), held.Soft_Held_By__c);
    System.assert(held.Soft_Hold_Until__c > System.now());
    // Same agent may refresh soft hold; exclusivity is other-agent only.
    System.assert(
      OutreachWorkbenchController.claimCandidate(e.Id),
      'Same agent can refresh soft hold'
    );
    // Another agent soft-hold blocks claimCandidate.
    held.Soft_Held_By__c = UserInfo.getUserId();
    // Use a distinct Id by temporarily pointing hold at a queue group id-shaped user:
    // create a second active user via runAs pattern below is heavy — set Until past then
    // re-apply foreign hold via cloning Soft_Held_By to a different User in org.
    List<User> others = [
      SELECT Id
      FROM User
      WHERE IsActive = TRUE AND Id != :UserInfo.getUserId()
      LIMIT 1
    ];
    if (!others.isEmpty()) {
      held.Soft_Held_By__c = others[0].Id;
      held.Soft_Hold_Until__c = System.now().addMinutes(30);
      update held;
      System.assert(
        !OutreachWorkbenchController.claimCandidate(e.Id),
        'Active soft hold by another agent must block claim'
      );
      held.Soft_Held_By__c = UserInfo.getUserId();
      held.Soft_Hold_Until__c = System.now().addMinutes(30);
      update held;
    }
    Group pesQueue = [
      SELECT Id
      FROM Group
      WHERE Type = 'Queue' AND DeveloperName = 'PES_Outreach'
      LIMIT 1
    ];
    // Soft-holder can release even when OwnerId remains the shared queue.
    OutreachWorkbenchController.releaseEpisode(e.Id);
    Outreach_Episode__c released = [
      SELECT Soft_Held_By__c, OwnerId, Status__c
      FROM Outreach_Episode__c
      WHERE Id = :e.Id
    ];
    System.assertEquals(null, released.Soft_Held_By__c);
    System.assertEquals(pesQueue.Id, released.OwnerId);
    System.assertEquals('Unclaimed', released.Status__c);
    System.assert(OutreachWorkbenchController.claimCandidate(e.Id));
    OutreachWorkbenchController.logOutcome(
      e.Id,
      'Snoozed',
      'Phone',
      'Call later',
      Date.today().addDays(3),
      false,
      null,
      null,
      null,
      null,
      null,
      false,
      false
    );
    Outreach_Episode__c snoozed = [
      SELECT
        Status__c,
        OwnerId,
        Next_Action_Date__c,
        Soft_Held_By__c,
        Soft_Hold_Until__c
      FROM Outreach_Episode__c
      WHERE Id = :e.Id
    ];
    System.assertEquals('Snoozed', snoozed.Status__c);
    System.assertEquals(null, snoozed.Soft_Held_By__c);
    System.assertEquals(Date.today().addDays(3), snoozed.Next_Action_Date__c);
    System.assertEquals(pesQueue.Id, snoozed.OwnerId);
    OutreachWorkbenchController.suppressNeed(
      a.Id,
      'NO_NEXT',
      'Patient requested pause',
      Date.today().addDays(30)
    );
    System.assertEquals(
      'Suppressed',
      [SELECT State__c FROM Patient_Need__c WHERE Patient__c = :a.Id].State__c
    );
    System.assertEquals(
      'Completed',
      [SELECT Status__c FROM Outreach_Episode__c WHERE Id = :e.Id].Status__c
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Suppression__c
        WHERE Patient__c = :a.Id AND Active__c = TRUE
      ]
    );
  }
  @IsTest
  static void openUnclaimedEpisodeClaimsThenFallsThrough() {
    Account a = patient('openclaim');
    insert new Patient_Need__c(
      Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
      Patient__c = a.Id,
      Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Pending',
      Priority__c = 'Routine',
      Points__c = 10
    );
    Account b = patient('openclaim2');
    insert new Patient_Need__c(
      Engine_Key__c = b.Id + ':NO_NEXT_FOLLOWUP:1',
      Patient__c = b.Id,
      Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Pending',
      Priority__c = 'Routine',
      Points__c = 10
    );
    List<Outreach_Episode__c> planned = OutreachEpisodePlanner.plan(
      new Set<Id>{ a.Id, b.Id }
    );
    System.assertEquals(2, planned.size());
    Outreach_Episode__c first = planned[0];
    Outreach_Episode__c second = planned[1];

    OutreachWorkbenchController.RowDTO claimed = OutreachWorkbenchController.openUnclaimedEpisode(
      first.Id,
      'All'
    );
    System.assertEquals(first.Id, claimed.episodeId);
    Outreach_Episode__c firstHeld = [
      SELECT Status__c, Soft_Held_By__c, Soft_Hold_Until__c
      FROM Outreach_Episode__c
      WHERE Id = :first.Id
    ];
    System.assertEquals('Unclaimed', firstHeld.Status__c);
    System.assertEquals(UserInfo.getUserId(), firstHeld.Soft_Held_By__c);
    System.assert(firstHeld.Soft_Hold_Until__c > System.now());

    List<User> others = [
      SELECT Id
      FROM User
      WHERE IsActive = TRUE AND Id != :UserInfo.getUserId()
      LIMIT 1
    ];
    System.assert(!others.isEmpty(), 'Need another active user for soft-hold exclusivity');
    firstHeld.Soft_Held_By__c = others[0].Id;
    firstHeld.Soft_Hold_Until__c = System.now().addMinutes(30);
    update firstHeld;

    OutreachWorkbenchController.RowDTO fallback = OutreachWorkbenchController.openUnclaimedEpisode(
      first.Id,
      'All'
    );
    System.assertEquals(
      second.Id,
      fallback.episodeId,
      'Soft-held by another agent must fall through to next queue episode'
    );
  }

  @IsTest
  static void targetedEvaluationResolvesStaleNeedAndSchedulerRuns() {
    Account a = patient('target');
    Patient_Need__c n = new Patient_Need__c(
      Engine_Key__c = a.Id + ':NO_NEXT_INITIAL:1',
      Patient__c = a.Id,
      Rule_Id__c = 'NO_NEXT_INITIAL',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Pending',
      Priority__c = 'Routine',
      Points__c = 10
    );
    insert n;
    OutreachEvaluationBatch.evaluateTargeted(new Set<Id>{ a.Id });
    System.assertEquals(
      'Resolved',
      [SELECT State__c FROM Patient_Need__c WHERE Id = :n.Id].State__c
    );
    System.assertEquals(
      0,
      [
        SELECT Active_Need_Count__c
        FROM Patient_Outreach_Profile__c
        WHERE Patient__c = :a.Id
      ]
      .Active_Need_Count__c
    );
    Test.startTest();
    new OutreachEvaluationScheduler().execute(null);
    Test.stopTest();
  }

  @IsTest
  static void targetedBatchExecutesAndFinishes() {
    Account a = patient('batch');
    Test.startTest();
    Id jobId = Database.executeBatch(
      new OutreachEvaluationBatch(new Set<Id>{ a.Id }),
      1
    );
    Test.stopTest();
    AsyncApexJob job = [
      SELECT Status, NumberOfErrors
      FROM AsyncApexJob
      WHERE Id = :jobId
    ];
    System.assertEquals('Completed', job.Status);
    System.assertEquals(0, job.NumberOfErrors);
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Patient_Outreach_Profile__c WHERE Patient__c = :a.Id]
    );
  }

  @IsTest
  static void oneFutureSnoozeDoesNotHideActionableNeed() {
    Account a = patient('mixed-snooze');
    Datetime wakeAt = System.now().addDays(5);
    insert new List<Patient_Need__c>{
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':OFF_CADENCE:1',
        Patient__c = a.Id,
        Rule_Id__c = 'OFF_CADENCE',
        Rule_Version__c = '1',
        Need_Type__c = 'OFF_CADENCE',
        State__c = 'Snoozed',
        Snooze_Until__c = wakeAt,
        Priority__c = 'STAT',
        Points__c = 90,
        Next_Action_Date__c = wakeAt.date()
      ),
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
        Patient__c = a.Id,
        Rule_Id__c = 'NO_NEXT_FOLLOWUP',
        Rule_Version__c = '1',
        Need_Type__c = 'NO_NEXT',
        State__c = 'Pending',
        Priority__c = 'Routine',
        Points__c = 10,
        Next_Action_Date__c = Date.today()
      )
    };
    Outreach_Episode__c episode = OutreachEpisodePlanner.plan(
      new Set<Id>{ a.Id }
    )[0];
    System.assertEquals('Unclaimed', episode.Status__c);
    System.assertEquals(Date.today(), episode.Next_Action_Date__c);
    System.assertEquals(
      90,
      episode.Points__c,
      'Points remain the maximum across all active needs.'
    );
  }

  @IsTest
  static void selectiveSnoozeLeavesOtherNeedsActionableAndNewRuleCanReturn() {
    Account a = patient('sel-snooze');
    insert new List<Patient_Need__c>{
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':OFF_CADENCE:1',
        Patient__c = a.Id,
        Rule_Id__c = 'OFF_CADENCE',
        Rule_Version__c = '1',
        Need_Type__c = 'OFF_CADENCE',
        State__c = 'Pending',
        Priority__c = 'Urgent',
        Points__c = 60,
        Next_Action_Date__c = Date.today()
      ),
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
        Patient__c = a.Id,
        Rule_Id__c = 'NO_NEXT_FOLLOWUP',
        Rule_Version__c = '1',
        Need_Type__c = 'NO_NEXT',
        State__c = 'Pending',
        Priority__c = 'Routine',
        Points__c = 40,
        Next_Action_Date__c = Date.today()
      ),
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':AWV_DUE:1',
        Patient__c = a.Id,
        Rule_Id__c = 'AWV_DUE',
        Rule_Version__c = '1',
        Need_Type__c = 'AWV',
        State__c = 'Pending',
        Priority__c = 'Urgent',
        Points__c = 90,
        Next_Action_Date__c = Date.today()
      )
    };
    Outreach_Episode__c e = OutreachEpisodePlanner.plan(new Set<Id>{ a.Id })[0];
    System.assert(OutreachWorkbenchController.claimCandidate(e.Id));
    Map<String, Id> needByRule = new Map<String, Id>();
    for (Patient_Need__c n : [
      SELECT Id, Rule_Id__c
      FROM Patient_Need__c
      WHERE Patient__c = :a.Id
    ])
      needByRule.put(n.Rule_Id__c, n.Id);

    Date wake = Date.today().addDays(21);
    OutreachWorkbenchController.logOutcome(
      e.Id,
      'Snoozed',
      'Phone',
      'Snooze off cadence + no next for 3 weeks',
      wake,
      true,
      new List<Id>{
        needByRule.get('OFF_CADENCE'),
        needByRule.get('NO_NEXT_FOLLOWUP')
      },
      null,
      null,
      null,
      null,
      false,
      false
    );

    Map<String, Patient_Need__c> afterByRule = new Map<String, Patient_Need__c>();
    for (Patient_Need__c n : [
      SELECT Rule_Id__c, State__c, Snooze_Until__c
      FROM Patient_Need__c
      WHERE Patient__c = :a.Id
    ])
      afterByRule.put(n.Rule_Id__c, n);

    System.assertEquals('Snoozed', afterByRule.get('OFF_CADENCE').State__c);
    System.assertEquals(
      'Snoozed',
      afterByRule.get('NO_NEXT_FOLLOWUP').State__c
    );
    System.assertEquals(
      'Pending',
      afterByRule.get('AWV_DUE').State__c,
      'Unselected AWV must stay actionable'
    );
    Outreach_Episode__c episode = [
      SELECT Status__c, Next_Action_Date__c
      FROM Outreach_Episode__c
      WHERE Id = :e.Id
    ];
    System.assertNotEquals(
      'Snoozed',
      episode.Status__c,
      'Episode stays queueable while an unselected care item is still active'
    );

    // New fourth rule while the two are still snoozed — patient remains actionable.
    insert new Patient_Need__c(
      Engine_Key__c = a.Id + ':CUSTOM_RULE:1',
      Patient__c = a.Id,
      Rule_Id__c = 'CUSTOM_RULE',
      Rule_Version__c = '1',
      Need_Type__c = 'OTHER',
      State__c = 'Pending',
      Priority__c = 'Urgent',
      Points__c = 70,
      Next_Action_Date__c = Date.today()
    );
    Outreach_Episode__c replanned = OutreachEpisodePlanner.plan(
      new Set<Id>{ a.Id }
    )[0];
    System.assertNotEquals(
      'Snoozed',
      replanned.Status__c,
      'A newly added care item can return the patient before snoozed items wake'
    );

    // Park everything, then fire a brand-new never-attempted care item → Unclaimed queue.
    Datetime wakeDt = Datetime.newInstance(wake, Time.newInstance(0, 0, 0, 0));
    List<Patient_Need__c> parkAll = [
      SELECT Id, State__c, Snooze_Until__c
      FROM Patient_Need__c
      WHERE Patient__c = :a.Id
    ];
    for (Patient_Need__c n : parkAll) {
      n.State__c = 'Snoozed';
      n.Snooze_Until__c = wakeDt;
    }
    update parkAll;
    Outreach_Episode__c parked = OutreachEpisodePlanner.plan(
      new Set<Id>{ a.Id }
    )[0];
    System.assertEquals('Snoozed', parked.Status__c);

    insert new Patient_Need__c(
      Engine_Key__c = a.Id + ':AWV_CATCHUP:1',
      Patient__c = a.Id,
      Rule_Id__c = 'AWV_DUE',
      Rule_Version__c = '2',
      Need_Type__c = 'AWV',
      State__c = 'Pending',
      Priority__c = 'Urgent',
      Points__c = 95,
      Attempt_Count__c = 0,
      Next_Action_Date__c = Date.today()
    );
    Outreach_Episode__c returned = OutreachEpisodePlanner.plan(
      new Set<Id>{ a.Id }
    )[0];
    System.assertEquals(
      'Unclaimed',
      returned.Status__c,
      'New never-attempted care item after full snooze returns patient to Unclaimed queue'
    );
    Id pesQueueId = [
      SELECT Id
      FROM Group
      WHERE Type = 'Queue' AND DeveloperName = 'PES_Outreach'
      LIMIT 1
    ]
    .Id;
    System.assertEquals(pesQueueId, returned.OwnerId);
  }

  @IsTest
  static void workspaceExposesEngagementPressureAndRationale() {
    Account a = patient('workspace-dto');
    a.Engagement_Score__c = 42;
    a.Pressure_Score__c = 12;
    update a;
    insert new List<Patient_Need__c>{
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':AWV_DUE:1',
        Patient__c = a.Id,
        Rule_Id__c = 'AWV_DUE',
        Rule_Version__c = '1',
        Need_Type__c = 'AWV',
        State__c = 'Pending',
        Priority__c = 'Urgent',
        Points__c = 90,
        Attempt_Count__c = 1,
        Next_Action_Date__c = Date.today()
      ),
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
        Patient__c = a.Id,
        Rule_Id__c = 'NO_NEXT_FOLLOWUP',
        Rule_Version__c = '1',
        Need_Type__c = 'NO_NEXT',
        State__c = 'Pending',
        Priority__c = 'Routine',
        Points__c = 40,
        Attempt_Count__c = 0,
        Next_Action_Date__c = Date.today().addDays(1)
      )
    };
    Outreach_Episode__c planned = OutreachEpisodePlanner.plan(
      new Set<Id>{ a.Id }
    )[0];
    System.assertEquals(
      'Urgent',
      planned.Priority__c,
      'Planner should surface the higher-priority need episode.'
    );

    OutreachWorkbenchController.RowDTO workspace = OutreachWorkbenchController.getPatientWorkspace(
      a.Id
    );
    System.assertNotEquals(
      null,
      workspace,
      'Workspace should load for patient'
    );
    System.assertEquals(
      42,
      workspace.engagementScore,
      'Engagement score should denorm from Account'
    );
    System.assertEquals(
      12,
      workspace.pressureScore,
      'Pressure score should denorm from Account'
    );
    System.assert(
      String.isNotBlank(workspace.attemptLabel) &&
      workspace.attemptLabel.contains('of'),
      'attemptLabel should look like "{n} of {max}"'
    );
    System.assertNotEquals(
      null,
      workspace.scoreGuidance,
      'scoreGuidance should be populated'
    );
    System.assert(
      String.isNotBlank(workspace.rationale) &&
        workspace.rationale.contains('Annual Wellness') &&
         (workspace.rationale.contains('without a future medical visit') ||
        workspace.rationale.contains('no next visit') ||
        workspace.rationale.contains('no future medical visit')),
      'Rationale should synthesize AWV + no-next situation facts'
    );
    System.assert(
      workspace.rationale.startsWith('The patient is'),
      'Rationale should use synthesized situation voice'
    );
    System.assert(
      !workspace.rationale.contains('Active needs: NO_NEXT'),
      'Rationale should not use raw Active needs: NO_NEXT phrasing'
    );
    System.assert(
      workspace.scoreChips != null && !workspace.scoreChips.isEmpty(),
      'scoreChips should not be empty'
    );
    System.assert(
      String.isNotBlank(workspace.priorityHeadline),
      'priorityHeadline should be set'
    );
    System.assert(
      workspace.maxAttempts != null && workspace.maxAttempts > 0,
      'maxAttempts should be positive'
    );
    System.assertEquals(
      planned.Id,
      workspace.episodeId,
      'Deterministic ordering should return the planned higher-points episode'
    );
  }

  @IsTest
  static void rationaleSynthesizesUnengagedOffCadenceAndNoNext() {
    Account a = patient('synth-needs');
    insert new List<Patient_Need__c>{
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':UNENGAGED_6_MONTH:1',
        Patient__c = a.Id,
        Rule_Id__c = 'UNENGAGED_6_MONTH',
        Rule_Version__c = '1',
        Need_Type__c = 'UNENGAGED',
        State__c = 'Pending',
        Priority__c = 'Urgent',
        Points__c = 80
      ),
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':UNENGAGED_OFF_CADENCE:1',
        Patient__c = a.Id,
        Rule_Id__c = 'UNENGAGED_OFF_CADENCE',
        Rule_Version__c = '1',
        Need_Type__c = 'UNENGAGED',
        State__c = 'Pending',
        Priority__c = 'Urgent',
        Points__c = 80
      ),
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':OFF_CADENCE:1',
        Patient__c = a.Id,
        Rule_Id__c = 'OFF_CADENCE',
        Rule_Version__c = '1',
        Need_Type__c = 'OFF_CADENCE',
        State__c = 'Pending',
        Priority__c = 'Urgent',
        Points__c = 60
      ),
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
        Patient__c = a.Id,
        Rule_Id__c = 'NO_NEXT_FOLLOWUP',
        Rule_Version__c = '1',
        Need_Type__c = 'NO_NEXT',
        State__c = 'Pending',
        Priority__c = 'Routine',
        Points__c = 40
      )
    };
    OutreachEpisodePlanner.plan(new Set<Id>{ a.Id });
    OutreachWorkbenchController.RowDTO workspace = OutreachWorkbenchController.getPatientWorkspace(
      a.Id
    );
    System.assertNotEquals(null, workspace);
    System.assert(
      workspace.rationale.contains('high risk') ||
      workspace.rationale.contains('not on cadence') ||
      workspace.rationale.contains('Off cadence'),
      workspace.rationale
    );
    System.assert(
      workspace.rationale.contains('6+ months overdue') ||
      workspace.rationale.contains('more than 6 months') ||
      workspace.rationale.contains('not on cadence'),
      workspace.rationale
    );
    System.assert(
      workspace.rationale.contains('no future medical visit') ||
      workspace.rationale.contains('without a future medical visit') ||
      workspace.rationale.contains('no future visit') ||
      workspace.rationale.contains('no next visit'),
      workspace.rationale
    );
    System.assert(
      !workspace.rationale.contains('Also:'),
      'Should synthesize instead of listing Also: clauses'
    );
  }
  @IsTest
  static void situationHelpersCoverPhraseBranchesAndJson() {
    enableRulesEngineMocked();
    // Direct @TestVisible coverage for synthesis helpers (keeps deploy >=75%).
    List<OutreachWorkbenchController.NeedDTO> needs = new List<OutreachWorkbenchController.NeedDTO>();
    for (
      String ruleId : new List<String>{
        'UNENGAGED_6_MONTH',
        'UNENGAGED_12_MONTH',
        'UNENGAGED_17_MONTH',
        'INACTIVE_18_MONTH',
        'UNENGAGED_OFF_CADENCE',
        'OFF_CADENCE',
        'AWV_DUE',
        'NO_NEXT_FOLLOWUP',
        'CUSTOM_RULE'
      }
    ) {
      OutreachWorkbenchController.NeedDTO n = new OutreachWorkbenchController.NeedDTO();
      n.ruleId = ruleId;
      n.needType = ruleId.contains('NO_NEXT')
        ? 'NO_NEXT'
        : (ruleId.contains('AWV')
            ? 'AWV'
            : (ruleId.contains('OFF_CADENCE')
                ? 'OFF_CADENCE'
                : (ruleId.contains('UNENGAGED') || ruleId.contains('INACTIVE')
                    ? 'UNENGAGED'
                    : 'OTHER')));
      n.priority = 'Urgent';
      n.points = 50;
      n.state = 'Pending';
      needs.add(n);
      System.assertNotEquals(
        null,
        OutreachWorkbenchController.situationPhraseFor(n)
      );
    }
    System.assertEquals(
      null,
      OutreachWorkbenchController.situationPhraseFor(null)
    );

    List<String> facts = OutreachWorkbenchController.situationFactsFor(needs);
    System.assert(
      facts.contains('inactive for 18 or more months'),
      String.valueOf(facts)
    );
    System.assert(
      facts.contains('currently not on cadence for their assigned tier'),
      String.valueOf(facts)
    );
    System.assert(
      facts.contains('due for an Annual Wellness Visit'),
      String.valueOf(facts)
    );
    System.assert(
      facts.contains('without a future medical visit scheduled'),
      String.valueOf(facts)
    );

    System.assertEquals(
      'The patient needs outreach.',
      OutreachWorkbenchController.synthesizeSituation(new List<String>())
    );
    System.assert(
      OutreachWorkbenchController.synthesizeSituation(
          new List<String>{ 'off cadence' }
        )
        .contains('off cadence')
    );
    System.assert(
      OutreachWorkbenchController.synthesizeSituation(
          new List<String>{
            'more than 6 months overdue for contact',
            'off cadence'
          }
        )
        .contains(' and ')
    );
    String three = OutreachWorkbenchController.synthesizeSituation(
      new List<String>{
        'more than 6 months overdue for contact',
        'currently not on cadence for their assigned tier',
        'without a future medical visit scheduled'
      }
    );
    System.assertEquals(
      'The patient is high risk and 6+ months overdue for an appointment, currently not on cadence for their assigned tier, and has no future medical visits scheduled.',
      three
    );
    System.assert(
      OutreachWorkbenchController.synthesizeSituation(
          new List<String>{ 'a', 'b', 'c', 'd' }
        )
        .contains(' with ')
    );

    OutreachWorkbenchController.RowDTO row = new OutreachWorkbenchController.RowDTO();
    row.priority = 'Urgent';
    row.points = 80;
    row.nextAction = 'Call — schedule visit';
    row.engagementScore = 10;
    row.scoreGuidance = 'Engagement test.';
    row.pressureLabel = '2 of 4';
    row.attemptCount = 2;
    row.maxAttempts = 4;
    row.needs = needs;
    String json = OutreachWorkbenchController.buildOutreachContextJson(row);
    System.assert(json.contains('situationFacts'));
    System.assert(json.contains('scheduleGuidance'));
    System.assert(json.contains('situationSummary'));
    System.assert(
      json.contains('more than 6 months overdue for contact') ||
      json.contains('inactive for 18')
    );
    System.assertEquals(
      null,
      OutreachWorkbenchController.cleanGenAIRationale(null)
    );
    System.assertEquals(
      'Hello',
      OutreachWorkbenchController.cleanGenAIRationale('"Hello"')
    );
    System.assertEquals(
      '{}',
      OutreachWorkbenchController.buildOutreachContextJson(null)
    );

    Account a = patient('helpers-queue');
    insert new Patient_Need__c(
      Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
      Patient__c = a.Id,
      Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Pending',
      Priority__c = 'Routine',
      Points__c = 40,
      Next_Action_Date__c = Date.today()
    );
    OutreachEpisodePlanner.plan(new Set<Id>{ a.Id });
    List<OutreachWorkbenchController.RowDTO> rows = OutreachWorkbenchController.getRows(
      25,
      null,
      'All'
    );
    System.assertNotEquals(null, rows);
    List<OutreachWorkbenchController.RowDTO> evalRows = OutreachWorkbenchController.evaluatePatients(
      new List<Id>{ a.Id }
    );
    System.assertNotEquals(null, evalRows);
  }

  @IsTest
  static void supersedenceCollapsesNeedCount() {
    Account a = patient('supercede-count');
    insert new List<Patient_Need__c>{
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':UNENGAGED_6_MONTH:1',
        Patient__c = a.Id,
        Rule_Id__c = 'UNENGAGED_6_MONTH',
        Rule_Version__c = '1',
        Need_Type__c = 'UNENGAGED',
        State__c = 'Pending',
        Priority__c = 'Urgent',
        Points__c = 80
      ),
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
        Patient__c = a.Id,
        Rule_Id__c = 'NO_NEXT_FOLLOWUP',
        Rule_Version__c = '1',
        Need_Type__c = 'NO_NEXT',
        State__c = 'Pending',
        Priority__c = 'Routine',
        Points__c = 40
      )
    };
    // Apply CMDT-driven supersedence the same way the evaluator does after matching.
    List<Outreach_Rule__mdt> rules = [
      SELECT Rule_Id__c, Need_Type__c, Family__c, Supersedes_Families__c
      FROM Outreach_Rule__mdt
      WHERE Rule_Id__c IN ('UNENGAGED_6_MONTH', 'NO_NEXT_FOLLOWUP')
    ];
    List<Patient_Need__c> writes = [
      SELECT Id, Patient__c, Rule_Id__c, Need_Type__c, State__c, Engine_Key__c
      FROM Patient_Need__c
      WHERE Patient__c = :a.Id
    ];
    OutreachRuleEvaluator.applyFamilySupersedence(writes, rules);
    update writes;
    OutreachEpisodePlanner.plan(new Set<Id>{ a.Id });
    Patient_Outreach_Profile__c profile = [
      SELECT Active_Need_Count__c
      FROM Patient_Outreach_Profile__c
      WHERE Patient__c = :a.Id
    ];
    System.assertEquals(
      2,
      profile.Active_Need_Count__c.intValue(),
      'Unengaged flavors no longer supersede No Next; both parents remain active'
    );
    OutreachWorkbenchController.RowDTO workspace = OutreachWorkbenchController.getPatientWorkspace(
      a.Id
    );
    System.assert(
      workspace.rationale.contains('high risk') ||
      workspace.rationale.contains('more than 6 months') ||
      workspace.rationale.contains('not on cadence') ||
      workspace.rationale.contains('without a future medical visit'),
      workspace.rationale
    );
    System.assert(
      workspace.rationale.contains('no future medical visit') ||
      workspace.rationale.contains('without a future medical visit') ||
      workspace.rationale.contains('no future visit') ||
      workspace.rationale.contains('no next visit'),
      'Situation should still mention missing next visit: ' +
      workspace.rationale
    );
  }


  @IsTest
  static void appendCtaSkipsSchedulingAndKeepsNonScheduling() {
    System.assertEquals(
      'Patient summary.',
      OutreachWorkbenchController.appendCtaToDescription(
        'Patient summary.',
        'Schedule the next medical visit.'
      )
    );
    System.assertEquals(
      'Patient summary. Restore cadence for the assigned tier.',
      OutreachWorkbenchController.appendCtaToDescription(
        'Patient summary.',
        'Restore cadence for the assigned tier.'
      )
    );
    System.assertEquals(
      true,
      OutreachWorkbenchController.isSchedulingCta('Call — schedule visit')
    );
    System.assertEquals(
      false,
      OutreachWorkbenchController.isSchedulingCta('Restore cadence for the assigned tier.')
    );
  }

  @IsTest
  static void silenceNeedRequiresReason() {
    Account a = patient('silence-blank');
    insert new Patient_Need__c(
      Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
      Patient__c = a.Id,
      Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Pending',
      Priority__c = 'Routine',
      Points__c = 40,
      Next_Action_Date__c = Date.today()
    );
    OutreachEpisodePlanner.plan(new Set<Id>{ a.Id });
    Patient_Need__c need = [
      SELECT Id FROM Patient_Need__c WHERE Patient__c = :a.Id LIMIT 1
    ];
    Boolean threw = false;
    try {
      OutreachWorkbenchController.silenceNeed(a.Id, need.Id, null, null);
    } catch (AuraHandledException e) {
      threw = true;
    }
    System.assertEquals(true, threw, 'Blank silence reason must fail');
    OutreachWorkbenchController.silenceNeed(a.Id, need.Id, 'Patient opted out', null);
    System.assertEquals(
      'Silenced',
      [SELECT State__c FROM Patient_Need__c WHERE Id = :need.Id].State__c
    );
  }

  @IsTest
  static void softHoldHiddenFromCareItemHistory() {
    Account a = patient('soft-hold-hist');
    insert new Patient_Need__c(
      Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
      Patient__c = a.Id,
      Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Pending',
      Priority__c = 'Routine',
      Points__c = 40,
      Next_Action_Date__c = Date.today()
    );
    OutreachEpisodePlanner.plan(new Set<Id>{ a.Id });
    OutreachWorkbenchController.recordSoftHold(a.Id);
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Outreach_Event__c
        WHERE Patient__c = :a.Id AND Event_Type__c = 'Reviewed Outreach'
      ]
    );
    for (OutreachWorkbenchController.EventDTO ev : OutreachWorkbenchController.getRecentEvents(
      a.Id,
      20
    )) {
      System.assertNotEquals(
        'Reviewed Outreach',
        ev.eventType,
        'Soft hold must not appear in Care Item History'
      );
    }
  }

  @IsTest
  static void softHoldSilenceAndSelectiveOutcome() {
    Account a = patient('soft-hold');
    insert new Patient_Need__c(
      Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
      Patient__c = a.Id,
      Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Pending',
      Priority__c = 'Routine',
      Points__c = 40,
      Next_Action_Date__c = Date.today()
    );
    Outreach_Episode__c e = OutreachEpisodePlanner.plan(new Set<Id>{ a.Id })[0];
    Test.startTest();
    OutreachWorkbenchController.RowDTO held = OutreachWorkbenchController.recordSoftHold(
      a.Id
    );
    System.assertNotEquals(null, held);
    // Second call same day must upsert — once per agent per patient per day.
    OutreachWorkbenchController.recordSoftHold(a.Id);
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Outreach_Event__c
        WHERE Patient__c = :a.Id AND Event_Type__c = 'Reviewed Outreach'
      ]
    );
    Patient_Need__c need = [
      SELECT Id
      FROM Patient_Need__c
      WHERE Patient__c = :a.Id
      LIMIT 1
    ];
    OutreachWorkbenchController.RowDTO silencedWorkspace = OutreachWorkbenchController.silenceNeed(
      a.Id,
      need.Id,
      'Patient asked not to be reminded',
      Date.today().addDays(30)
    );
    System.assertEquals(
      'Silenced',
      [SELECT State__c FROM Patient_Need__c WHERE Id = :need.Id].State__c
    );
    // Episode may be Completed after silence, but silenceNeed must still return
    // a workspace so the Silenced / Unsilence UI remains available.
    System.assertNotEquals(
      null,
      silencedWorkspace,
      'Workspace should remain available after silencing the last care item'
    );
    Boolean sawSilenced = false;
    if (silencedWorkspace.needs != null) {
      for (OutreachWorkbenchController.NeedDTO n : silencedWorkspace.needs) {
        if (n.id == need.Id && n.state == 'Silenced') {
          sawSilenced = true;
          break;
        }
      }
    }
    System.assertEquals(true, sawSilenced, 'Silenced need must remain on the workspace');
    OutreachWorkbenchController.unsilenceNeed(a.Id, need.Id);
    System.assertEquals(
      'Pending',
      [SELECT State__c FROM Patient_Need__c WHERE Id = :need.Id].State__c
    );
    OutreachWorkbenchController.RowDTO after = OutreachWorkbenchController.logOutcome(
      e.Id,
      'Left Message',
      'Phone',
      'Covered on call',
      null,
      false,
      new List<Id>{ need.Id },
      new List<Id>(),
      null,
      null,
      null,
      false,
      false
    );
    System.assertNotEquals(null, after);
    Patient_Need__c attemptedNeed = [
      SELECT State__c, Attempt_Count__c
      FROM Patient_Need__c
      WHERE Id = :need.Id
    ];
    System.assertEquals(1, attemptedNeed.Attempt_Count__c);
    System.assertEquals('Snoozed', attemptedNeed.State__c);
    Outreach_Episode__c afterEp = [
      SELECT OwnerId, Soft_Held_By__c, Status__c
      FROM Outreach_Episode__c
      WHERE Id = :e.Id
    ];
    Group pesQueue = [
      SELECT Id
      FROM Group
      WHERE Type = 'Queue' AND DeveloperName = 'PES_Outreach'
      LIMIT 1
    ];
    System.assertEquals(pesQueue.Id, afterEp.OwnerId);
    System.assertEquals(null, afterEp.Soft_Held_By__c);
    System.assert(
      afterEp.Status__c == 'Unclaimed' || afterEp.Status__c == 'Snoozed',
      'Auto-release leaves episode Unclaimed or cadence-Snoozed, not agent-owned'
    );
    Test.stopTest();
    Map<String, String> rec = OutreachWorkbenchController.enhanceRecommendedAction(
      a.Id
    );
    System.assertNotEquals(null, rec);
    System.assert(rec.containsKey('recommendedAction'));
  }

  @IsTest
  static void keepWorkingRetainsSoftHold() {
    Account a = patient('keep-working');
    insert new Patient_Need__c(
      Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
      Patient__c = a.Id,
      Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Pending',
      Priority__c = 'Routine',
      Points__c = 10,
      Next_Action_Date__c = Date.today()
    );
    Outreach_Episode__c e = OutreachEpisodePlanner.plan(new Set<Id>{ a.Id })[0];
    OutreachWorkbenchController.claimEpisode(e.Id);
    Patient_Need__c need = [
      SELECT Id FROM Patient_Need__c WHERE Patient__c = :a.Id LIMIT 1
    ];
    OutreachWorkbenchController.logOutcome(
      e.Id,
      'Left Message',
      'Phone',
      'Still working',
      null,
      false,
      new List<Id>{ need.Id },
      new List<Id>(),
      null,
      null,
      null,
      false,
      true
    );
    Outreach_Episode__c afterEp = [
      SELECT Soft_Held_By__c, Soft_Hold_Until__c, OwnerId, Status__c
      FROM Outreach_Episode__c
      WHERE Id = :e.Id
    ];
    System.assertEquals(UserInfo.getUserId(), afterEp.Soft_Held_By__c);
    System.assert(afterEp.Soft_Hold_Until__c > System.now());
    System.assert(
      afterEp.Status__c == 'Unclaimed' || afterEp.Status__c == 'Snoozed',
      'Keep working retains soft hold regardless of cadence status'
    );
  }

  @IsTest
  static void enhanceRationaleFallsBackToRuleEngine() {
    Account a = patient('enhance-rationale');
    insert new Patient_Need__c(
      Engine_Key__c = a.Id + ':AWV_DUE:1',
      Patient__c = a.Id,
      Rule_Id__c = 'AWV_DUE',
      Rule_Version__c = '1',
      Need_Type__c = 'AWV',
      State__c = 'Pending',
      Priority__c = 'Urgent',
      Points__c = 90,
      Attempt_Count__c = 0,
      Next_Action_Date__c = Date.today()
    );
    OutreachEpisodePlanner.plan(new Set<Id>{ a.Id });

    Map<String, String> result = OutreachWorkbenchController.enhanceRationale(
      a.Id
    );
    System.assertNotEquals(
      null,
      result,
      'enhanceRationale should return a map'
    );
    System.assertEquals(
      'RuleEngine',
      result.get('rationaleSource'),
      'Test context should soft-fallback to RuleEngine'
    );
    System.assert(
      String.isNotBlank(result.get('rationale')),
      'Fallback rationale should be non-blank'
    );
  }

  @IsTest
  static void careItemEventEnrichmentCoversParentKeysAndSummaries() {
    System.assertEquals(
      'OFF_CADENCE',
      OutreachWorkbenchController.careItemParentKey(
        'OFF_CADENCE',
        'OFF_CADENCE',
        'OFF_CADENCE'
      )
    );
    System.assertEquals(
      'NO_NEXT',
      OutreachWorkbenchController.careItemParentKey(
        'NO_NEXT_FOLLOWUP',
        'NO_NEXT',
        'NO_NEXT'
      )
    );
    System.assertEquals(
      'AWV',
      OutreachWorkbenchController.careItemParentKey('AWV_DUE', 'AWV', 'AWV')
    );
    System.assertEquals(
      'UNENGAGED',
      OutreachWorkbenchController.careItemParentKey(
        'UNENGAGED_6_MONTH',
        'UNENGAGED',
        'UNENGAGED'
      )
    );
    System.assertEquals(
      'INACTIVE',
      OutreachWorkbenchController.careItemParentKey(
        'INACTIVE_18_MONTH',
        'INACTIVE',
        null
      )
    );
    System.assertEquals(
      'Off cadence',
      OutreachWorkbenchController.careItemParentLabel('OFF_CADENCE', 'x')
    );
    System.assertEquals(
      'No next visit',
      OutreachWorkbenchController.careItemParentLabel('NO_NEXT', 'x')
    );

    OutreachWorkbenchController.EventDTO opened = new OutreachWorkbenchController.EventDTO();
    opened.eventType = 'Need Opened';
    opened.ruleId = 'OFF_CADENCE';
    OutreachWorkbenchController.enrichEventPlainLanguage(
      opened,
      new Map<String, Outreach_Rule__mdt>()
    );
    System.assertEquals('Care Item Opened', opened.eventType);
    System.assert(
      opened.summary != null && opened.summary.contains('became active'),
      opened.summary
    );
    System.assertEquals('OFF_CADENCE', opened.careItemKey);

    OutreachWorkbenchController.EventDTO closed = new OutreachWorkbenchController.EventDTO();
    closed.eventType = 'Need Closed';
    closed.ruleId = 'NO_NEXT_FOLLOWUP';
    OutreachWorkbenchController.enrichEventPlainLanguage(
      closed,
      new Map<String, Outreach_Rule__mdt>()
    );
    System.assertEquals('Care Item Closed', closed.eventType);
    System.assert(
      closed.summary != null && closed.summary.contains('was closed'),
      closed.summary
    );

    OutreachWorkbenchController.EventDTO reviewed = new OutreachWorkbenchController.EventDTO();
    reviewed.eventType = 'Reviewed Outreach';
    reviewed.outcome = 'Soft Hold';
    OutreachWorkbenchController.enrichEventPlainLanguage(reviewed, null);
    System.assertEquals('ACTIVITY', reviewed.careItemKey);
    System.assertEquals('Outreach activity', reviewed.careItemLabel);
    System.assertEquals(
      'Soft hold recorded (reviewed outreach)',
      reviewed.summary
    );

    OutreachWorkbenchController.enrichEventPlainLanguage(null, null);
  }

  @IsTest
  static void wakeAndExtendSnoozedNeed() {
    Account a = patient('wake-ext');
    insert new Patient_Need__c(
      Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
      Patient__c = a.Id,
      Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Snoozed',
      Snooze_Until__c = System.now().addDays(10),
      Priority__c = 'Routine',
      Points__c = 40,
      Next_Action_Date__c = Date.today().addDays(10)
    );
    OutreachEpisodePlanner.plan(new Set<Id>{ a.Id });
    Id needId = [
      SELECT Id
      FROM Patient_Need__c
      WHERE Patient__c = :a.Id
      LIMIT 1
    ]
    .Id;
    OutreachWorkbenchController.extendNeedSnooze(
      a.Id,
      needId,
      Date.today().addDays(30)
    );
    System.assertEquals(
      Date.today().addDays(30),
      [SELECT Snooze_Until__c FROM Patient_Need__c WHERE Id = :needId]
        .Snooze_Until__c.date()
    );
    OutreachWorkbenchController.wakeNeed(a.Id, needId);
    Patient_Need__c woken = [
      SELECT State__c, Snooze_Until__c
      FROM Patient_Need__c
      WHERE Id = :needId
    ];
    System.assertEquals('Pending', woken.State__c);
    System.assertEquals(null, woken.Snooze_Until__c);
  }

  @IsTest
  static void terminalOutcomesAndAccountUpdatesUseCanonicalFields() {
    System.assert(
      OutreachWorkbenchController.isClosedDisposition('Appointment Scheduled')
    );
    System.assert(
      OutreachWorkbenchController.isClosedDisposition('Inactive Patient')
    );
    System.assert(
      OutreachWorkbenchController.isClosedDisposition('Patient Deceased')
    );
    System.assert(
      OutreachWorkbenchController.isClosedDisposition(
        'Patient Refused Scheduling'
      )
    );
    System.assert(
      !OutreachWorkbenchController.isClosedDisposition('Unable to Reach')
    );
    System.assert(
      !OutreachWorkbenchController.isClosedDisposition(
        'Escalated for Service Recovery'
      )
    );
    System.assert(
      !OutreachWorkbenchController.isClosedDisposition('Results Received')
    );

    Id patientId = '001000000000001AAA';
    Account inactive = OutreachWorkbenchController.accountStatusUpdateForOutcome(
      patientId,
      'Inactive Patient',
      'Moved',
      null
    );
    System.assertEquals('i', inactive.HealthCloudGA__Active__c);
    System.assertEquals('Moved', inactive.Inactive_Reasons__c);

    Datetime occurredAt = Datetime.newInstance(2026, 7, 20, 12, 0, 0);
    Account deceased = OutreachWorkbenchController.accountStatusUpdateForOutcome(
      patientId,
      'Patient Deceased',
      null,
      occurredAt
    );
    System.assertEquals(occurredAt, deceased.PersonDeceasedDate);
    System.assertEquals(
      null,
      OutreachWorkbenchController.accountStatusUpdateForOutcome(
        patientId,
        'Left Message',
        null,
        occurredAt
      )
    );
  }

  @IsTest
  static void attemptCadenceSnoozesThenExhausts() {
    enableRulesEngineMocked();
    Cadence_Policy__mdt policy = new Cadence_Policy__mdt(
      Max_Attempts__c = 2,
      Attempt_Interval_Days__c = 7
    );
    OutreachRulesEngineClient.mockReactionJson =
      '{"result":{"suppressDays":0,"snoozeDays":7,"resolve":false,"reason":"Attempt cadence"}}';
    Patient_Need__c firstAttempt = new Patient_Need__c(
      Attempt_Count__c = 1,
      Need_Type__c = 'NO_NEXT',
      Rule_Id__c = 'NO_NEXT_FOLLOWUP'
    );
    OutreachWorkbenchController.applyAttemptCadence(firstAttempt, policy);
    System.assertEquals('Snoozed', firstAttempt.State__c);
    System.assertEquals(
      Date.today().addDays(7),
      firstAttempt.Next_Action_Date__c
    );
    System.assertEquals(
      Date.today().addDays(7),
      firstAttempt.Snooze_Until__c.date()
    );

    OutreachRulesEngineClient.mockReactionJson =
      '{"result":{"suppressDays":0,"snoozeDays":0,"resolve":true,"reason":"Max attempts reached"}}';
    Patient_Need__c finalAttempt = new Patient_Need__c(
      Attempt_Count__c = 2,
      Need_Type__c = 'NO_NEXT',
      Rule_Id__c = 'NO_NEXT_FOLLOWUP'
    );
    OutreachWorkbenchController.applyAttemptCadence(finalAttempt, policy);
    System.assertEquals('Resolved', finalAttempt.State__c);
    System.assertEquals(
      'Max attempts reached',
      finalAttempt.Resolution_Reason__c
    );
    System.assertEquals(null, finalAttempt.Snooze_Until__c);
  }
  @IsTest
  static void recentCommentsAndAppointmentHistoryApis() {
    Account a = patient('hist-apis');
    insert new Patient_Need__c(
      Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
      Patient__c = a.Id,
      Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Pending',
      Priority__c = 'Routine',
      Points__c = 40,
      Next_Action_Date__c = Date.today()
    );
    Outreach_Episode__c e = OutreachEpisodePlanner.plan(new Set<Id>{ a.Id })[0];
    OutreachEventService.EventRequest r = new OutreachEventService.EventRequest();
    r.patientId = a.Id;
    r.episodeId = e.Id;
    r.eventType = 'Comment';
    r.outcome = 'Comment Only';
    r.detail = 'Recent comment for history panel';
    r.idempotencyKey = a.Id + ':Comment:hist';
    OutreachEventService.append(new List<OutreachEventService.EventRequest>{ r });
    List<OutreachWorkbenchController.CommentDTO> comments =
      OutreachWorkbenchController.getRecentComments(a.Id, 10);
    System.assert(!comments.isEmpty(), 'Expected recent comments');
    System.assertEquals(
      'Recent comment for history panel',
      comments[0].detail
    );
    insert new List<Appointment__c>{
      new Appointment__c(
        Patient__c = a.Id,
        Athena_Appointment_Id__c = 'E2E-APPT-C-' + String.valueOf(Datetime.now().getTime()),
        Status__c = 'Cancelled',
        Start_Date_Time__c = System.now().addDays(5),
        Scheduled_Date__c = System.now().addDays(-1)
      ),
      new Appointment__c(
        Patient__c = a.Id,
        Athena_Appointment_Id__c = 'E2E-APPT-F-' + String.valueOf(Datetime.now().getTime()),
        Status__c = 'filled',
        Start_Date_Time__c = System.now().addDays(8),
        Scheduled_Date__c = System.now()
      )
    };
    List<OutreachWorkbenchController.EventDTO> appts =
      OutreachWorkbenchController.getAppointmentHistory(a.Id, 10);
    System.assert(!appts.isEmpty(), 'Expected appointment timeline rows');
    Boolean sawSchedOrResched = false;
    for (OutreachWorkbenchController.EventDTO ev : appts) {
      if (ev.eventType == 'Scheduled' || ev.eventType == 'Rescheduled' || ev.eventType == 'Cancelled')
        sawSchedOrResched = true;
    }
    System.assertEquals(true, sawSchedOrResched);
  }

  @IsTest
  static void overrideSnoozeEnforcesDateBounds() {
    Account a = patient('override-bounds');
    insert new Patient_Need__c(
      Engine_Key__c = a.Id + ':NO_NEXT_FOLLOWUP:1',
      Patient__c = a.Id,
      Rule_Id__c = 'NO_NEXT_FOLLOWUP',
      Rule_Version__c = '1',
      Need_Type__c = 'NO_NEXT',
      State__c = 'Snoozed',
      Snooze_Until__c = System.now().addDays(5),
      Priority__c = 'Routine',
      Points__c = 40,
      Next_Action_Date__c = Date.today().addDays(5)
    );
    OutreachEpisodePlanner.plan(new Set<Id>{ a.Id });
    Id needId = [
      SELECT Id FROM Patient_Need__c WHERE Patient__c = :a.Id LIMIT 1
    ]
    .Id;
    Boolean tooSoon = false;
    try {
      OutreachWorkbenchController.extendNeedSnooze(a.Id, needId, Date.today());
    } catch (AuraHandledException ex) {
      tooSoon = true;
    }
    System.assertEquals(true, tooSoon);
    Boolean tooFar = false;
    try {
      OutreachWorkbenchController.extendNeedSnooze(
        a.Id,
        needId,
        Date.today().addDays(400)
      );
    } catch (AuraHandledException ex) {
      tooFar = true;
    }
    System.assertEquals(true, tooFar);
    OutreachWorkbenchController.extendNeedSnooze(
      a.Id,
      needId,
      Date.today().addDays(21)
    );
    System.assertEquals(
      Date.today().addDays(21),
      [
          SELECT Snooze_Until__c
          FROM Patient_Need__c
          WHERE Id = :needId
        ]
        .Snooze_Until__c.date()
    );
  }

  @IsTest
  static void eventAppendRequiresPatientAndType() {
    Boolean threw = false;
    try {
      OutreachEventService.EventRequest bad = new OutreachEventService.EventRequest();
      bad.idempotencyKey = 'x';
      bad.eventType = 'Comment';
      OutreachEventService.append(new List<OutreachEventService.EventRequest>{ bad });
    } catch (Exception e) {
      threw = true;
    }
    System.assertEquals(true, threw);
  }

}
