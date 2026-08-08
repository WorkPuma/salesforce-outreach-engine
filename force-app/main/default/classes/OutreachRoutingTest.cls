@IsTest
private class OutreachRoutingTest {
  @IsTest
  static void priorityBucketsAndPointsOrder() {
    Integer stat = OutreachRoutingPriority.calculate('STAT', 10, Date.today());
    Integer urgent = OutreachRoutingPriority.calculate('Urgent', 100, Date.today());
    Integer routine = OutreachRoutingPriority.calculate('Routine', 10, Date.today());
    System.assert(stat < urgent, 'STAT before Urgent');
    System.assert(urgent < routine, 'Urgent before Routine');
    System.assert(
      OutreachRoutingPriority.calculate('Routine', 20, Date.today()) <
        OutreachRoutingPriority.calculate('Routine', 10, Date.today()),
      'Higher points sort first'
    );
  }

  @IsTest
  static void engagementStrategiesShiftOrder() {
    OutreachQueuePolicy.Config c = new OutreachQueuePolicy.Config();
    c.pressureBlockEnabled = true;
    c.pressureBlockThreshold = 80;
    c.rankingStrategy = 'HIGH';
    c.engagementWeight = 500;
    c.rangeMin = 40;
    c.rangeMax = 80;
    c.randomSaltHours = 24;
    OutreachQueuePolicy.configOverride = c;

    Integer lowEng = OutreachRoutingPriority.calculate(
      'Routine',
      10,
      Date.today(),
      -90,
      UserInfo.getUserId()
    );
    Integer highEng = OutreachRoutingPriority.calculate(
      'Routine',
      10,
      Date.today(),
      90,
      UserInfo.getUserId()
    );
    System.assert(highEng < lowEng, 'HIGH strategy prefers high engagement');

    c.rankingStrategy = 'LOW';
    OutreachQueuePolicy.configOverride = c;
    Integer lowPref = OutreachRoutingPriority.calculate(
      'Routine',
      10,
      Date.today(),
      -90,
      UserInfo.getUserId()
    );
    Integer highPref = OutreachRoutingPriority.calculate(
      'Routine',
      10,
      Date.today(),
      90,
      UserInfo.getUserId()
    );
    System.assert(lowPref < highPref, 'LOW strategy prefers low engagement');

    c.rankingStrategy = 'NEUTRAL';
    OutreachQueuePolicy.configOverride = c;
    System.assertEquals(
      0,
      OutreachRoutingPriority.engagementBoost(90, UserInfo.getUserId())
    );

    System.assertEquals(true, OutreachQueuePolicy.isPressureBlocked(80));
    System.assertEquals(false, OutreachQueuePolicy.isPressureBlocked(79.9));

    c.rankingStrategy = 'RANGE';
    OutreachQueuePolicy.configOverride = c;
    Decimal inRange = OutreachRoutingPriority.engagementBoost(60, UserInfo.getUserId());
    Decimal outRange = OutreachRoutingPriority.engagementBoost(-90, UserInfo.getUserId());
    System.assert(inRange > 0, 'RANGE boosts in-band scores');
    System.assertEquals(0, outRange, 'RANGE neutral outside band');

    c.rankingStrategy = 'RANDOM';
    OutreachQueuePolicy.configOverride = c;
    Decimal r = OutreachRoutingPriority.engagementBoost(0, UserInfo.getUserId());
    System.assert(r >= 0 && r <= c.engagementWeight, 'RANDOM within weight');
  }
}
