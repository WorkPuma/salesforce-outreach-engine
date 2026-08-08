@IsTest
private class OutreachRulesEngineFactBuilderTest {
  @IsTest
  static void buildsEmptyForBlankIds() {
    Map<Id, Map<String, Object>> out = OutreachRulesEngineFactBuilder.buildForAccounts(
      new Set<Id>(),
      new Set<String>()
    );
    System.assertEquals(0, out.size());
  }

  @IsTest
  static void buildsFactsForPersonAccount() {
    Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
      .get('PersonAccount')
      .getRecordTypeId();
    Account a = new Account(
      LastName = 'RulesEngine FactTest',
      RecordTypeId = rt,
      SourceSystemIdentifier = 'RULESENGINE-FACT-1'
    );
    insert a;
    a = [
      SELECT Id
      FROM Account
      WHERE Id = :a.Id
    ];
    Set<String> suppressed = new Set<String>{
      a.Id + ':AWV',
      a.Id + ':OFF_CADENCE',
      a.Id + ':NO_NEXT'
    };
    Test.startTest();
    Map<Id, Map<String, Object>> out = OutreachRulesEngineFactBuilder.buildForAccounts(
      new Set<Id>{ a.Id },
      suppressed
    );
    Test.stopTest();
    System.assertEquals(1, out.size());
    Map<String, Object> facts = out.get(a.Id);
    System.assertEquals(true, facts.get('suppressedAWV'));
    System.assertEquals(a.Id, facts.get('patientId'));
    System.assert(facts.containsKey('isMedicareProduct'));
    System.assert(facts.containsKey('awvDueWithin60'));
    System.assert(facts.containsKey('engagementScore'));
    System.assert(facts.containsKey('pressureScore'));
    System.assert(facts.containsKey('pressureBlocked'));
    System.assert(facts.containsKey('today'));
    System.assert(facts.containsKey('lastAwvDate'));
    System.assert(facts.containsKey('nextAwvDueDate'));
    System.assert(facts.containsKey('lastCompletedVisitDate'));
  }
}
