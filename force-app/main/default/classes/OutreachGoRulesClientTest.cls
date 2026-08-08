@IsTest
private class OutreachRulesEngineClientTest {
  private static void enableMockSettings() {
    OutreachRulesEngineClient.settingsOverride = new OutreachRulesEngineClient.Settings();
    OutreachRulesEngineClient.settingsOverride.enabled = true;
    OutreachRulesEngineClient.settingsOverride.projectSlug = 'patient-outreach';
    OutreachRulesEngineClient.settingsOverride.surfaceKey = 'outreach-surface';
    OutreachRulesEngineClient.settingsOverride.reactionKey = 'outreach-reaction';
    OutreachRulesEngineClient.settingsOverride.namedCredential = 'RulesEngine_Agent';
    OutreachRulesEngineClient.settingsOverride.batchSize = 20;
  }

  @IsTest
  static void parsesSurfaceAndReaction() {
    enableMockSettings();
    System.assertEquals(true, OutreachRulesEngineClient.isEnabled());
    System.assertEquals(20, OutreachRulesEngineClient.settings().batchSize);

    OutreachRulesEngineClient.mockSurfaceJson =
      '{"result":[{"eligible":true,"ruleId":"AWV_DUE","family":"AWV","needType":"AWV","category":"Scheduling","priority":"Routine","points":60,"shadowOnly":false,"createWork":true},{"eligible":false,"ruleId":"SKIP"}]}';
    List<OutreachRulesEngineClient.SurfaceHit> hits = OutreachRulesEngineClient.evaluateSurface(
      new Map<String, Object>{ 'patientId' => '001xx' }
    );
    System.assertEquals(1, hits.size());
    System.assertEquals('AWV_DUE', hits[0].ruleId);
    System.assertEquals(60, hits[0].points);

    OutreachRulesEngineClient.mockReactionJson =
      '{"result":{"suppressDays":7,"snoozeDays":7,"resolve":false,"suppressFamily":"AWV","reason":"Attempt Made"}}';
    OutreachRulesEngineClient.ReactionResult rx = OutreachRulesEngineClient.evaluateReaction(
      new Map<String, Object>{ 'outcome' => 'Left Message' }
    );
    System.assertEquals(7, rx.suppressDays);
    System.assertEquals(false, rx.resolve);
    System.assertEquals('AWV', rx.suppressFamily);

    OutreachRulesEngineClient.mockSurfaceJson =
      '{"result":[{"eligible":true,"ruleId":"AWV_DUE","family":"AWV","needType":"AWV","category":"Scheduling","priority":"Routine","points":60,"shadowOnly":false,"createWork":true,"scheduleBoundType":"ANYTIME_AFTER","scheduleEarliest":"2026-08-01","schedulePhrase":"","statusLabel":"Due for an AWV"}]}';
    hits = OutreachRulesEngineClient.evaluateSurface(new Map<String, Object>());
    System.assertEquals(1, hits.size());
    System.assertEquals('ANYTIME_AFTER', hits[0].scheduleBoundType);
    System.assertEquals('2026-08-01', hits[0].scheduleEarliest);
    System.assertEquals('Due for an AWV', hits[0].statusLabel);

    OutreachRulesEngineClient.mockSurfaceJson =
      '{"result":[{"eligible":true,"ruleId":"OFF_CADENCE","family":"OFF_CADENCE","needType":"OFF_CADENCE","category":"Scheduling","priority":"Urgent","points":80,"shadowOnly":false,"createWork":true,"scheduleBoundType":"ON_OR_BEFORE","scheduleLatestOffsetDays":45,"statusLabel":"Off Cadence"}]}';
    hits = OutreachRulesEngineClient.evaluateSurface(new Map<String, Object>());
    System.assertEquals(45, hits[0].scheduleLatestOffsetDays);
    System.assertEquals('Off Cadence', hits[0].statusLabel);
  }

  @IsTest
  static void parsesSingleObjectSurfaceAndResolveReaction() {
    enableMockSettings();
    OutreachRulesEngineClient.mockSurfaceJson =
      '{"result":{"eligible":true,"ruleId":"OFF_CADENCE","family":"OFF_CADENCE","needType":"OFF_CADENCE","points":80,"shadowOnly":false}}';
    List<OutreachRulesEngineClient.SurfaceHit> hits = OutreachRulesEngineClient.evaluateSurface(
      new Map<String, Object>()
    );
    System.assertEquals(1, hits.size());
    System.assertEquals('OFF_CADENCE', hits[0].ruleId);

    OutreachRulesEngineClient.mockReactionJson =
      '[{"resolve":true,"suppressDays":0,"snoozeDays":0,"reason":"Appointment Scheduled","suppressFamily":"AWV"}]';
    OutreachRulesEngineClient.ReactionResult rx = OutreachRulesEngineClient.evaluateReaction(
      new Map<String, Object>{ 'outcome' => 'Appointment Scheduled' }
    );
    System.assertEquals(true, rx.resolve);
  }

  @IsTest
  static void calloutMockEvaluate() {
    enableMockSettings();
    OutreachRulesEngineClient.mockSurfaceJson = null;
    Test.setMock(
      HttpCalloutMock.class,
      new RulesEngineHttpMock(
        200,
        '{"result":[{"eligible":true,"ruleId":"NO_NEXT_FOLLOWUP","family":"NO_NEXT","needType":"NO_NEXT","points":100,"shadowOnly":false,"createWork":true}]}'
      )
    );
    Test.startTest();
    List<OutreachRulesEngineClient.SurfaceHit> hits = OutreachRulesEngineClient.evaluateSurface(
      new Map<String, Object>{ 'totalApptCount' => 1 }
    );
    Test.stopTest();
    System.assertEquals(1, hits.size());
    System.assertEquals('NO_NEXT_FOLLOWUP', hits[0].ruleId);
  }

  @IsTest
  static void calloutErrorThrows() {
    enableMockSettings();
    OutreachRulesEngineClient.mockSurfaceJson = null;
    Test.setMock(HttpCalloutMock.class, new RulesEngineHttpMock(500, 'boom'));
    Boolean threw = false;
    try {
      OutreachRulesEngineClient.evaluateSurface(new Map<String, Object>());
    } catch (OutreachRulesEngineClient.RulesEngineException ex) {
      threw = true;
      System.assert(ex.getMessage().contains('500'));
    }
    System.assertEquals(true, threw);
  }

  private class RulesEngineHttpMock implements HttpCalloutMock {
    Integer code;
    String body;
    RulesEngineHttpMock(Integer code, String body) {
      this.code = code;
      this.body = body;
    }
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(code);
      res.setBody(body);
      res.setHeader('Content-Type', 'application/json');
      return res;
    }
  }

  @IsTest
  static void readsCmdtSettingsWhenNoOverride() {
    OutreachRulesEngineClient.settingsOverride = null;
    OutreachRulesEngineClient.Settings s = OutreachRulesEngineClient.settings();
    System.assertNotEquals(null, s.projectSlug);
    System.assertNotEquals(null, s.surfaceKey);
    System.assertNotEquals(null, s.reactionKey);
    System.assertNotEquals(null, s.namedCredential);
    System.assert(s.batchSize >= 1);
    // CMDT Default exists in org; exercise isEnabled path without override.
    Boolean enabled = OutreachRulesEngineClient.isEnabled();
    System.assertEquals(s.enabled == true, enabled);
  }

}
