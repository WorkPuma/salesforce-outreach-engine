@IsTest
private class OutreachOutcomeCatalogTest {
  @IsTest
  static void catalogReturnsEnabledResults() {
    Test.startTest();
    OutreachOutcomeCatalog.CatalogDTO c = OutreachOutcomeCatalog.getCatalog();
    Test.stopTest();
    System.assertNotEquals(null, c);
    System.assert(c.callResults != null && !c.callResults.isEmpty(), 'Call results expected');
    System.assert(c.channels != null && !c.channels.isEmpty(), 'Channels expected');
    System.assertEquals(
      'Appointment Scheduled',
      OutreachOutcomeCatalog.eventTypeForOutcome('Appointment Scheduled')
    );
    System.assertEquals(
      'Attempt Made',
      OutreachOutcomeCatalog.eventTypeForOutcome('No Answer')
    );
    System.assertEquals(
      true,
      OutreachOutcomeCatalog.closesCareItem('Appointment Scheduled')
    );
  }
}
