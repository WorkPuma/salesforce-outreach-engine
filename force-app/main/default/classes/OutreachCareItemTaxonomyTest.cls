@IsTest
private class OutreachCareItemTaxonomyTest {
  @IsTest
  static void parentKeyAndCollapse() {
    System.assertEquals(
      'AWV',
      OutreachCareItemTaxonomy.parentKey('AWV_DUE', 'AWV', null)
    );
    System.assertEquals(
      'OFF_CADENCE',
      OutreachCareItemTaxonomy.parentKey('OFF_CADENCE', 'OFF_CADENCE', null)
    );
    System.assertEquals(
      'NO_NEXT',
      OutreachCareItemTaxonomy.parentKey('NO_NEXT_FOLLOWUP', 'NO_NEXT', null)
    );
    System.assertEquals(
      'Unengaged',
      OutreachCareItemTaxonomy.parentLabel('UNENGAGED', null)
    );

    Account a = new Account(
      LastName = 'Taxonomy',
      RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
        .get('PersonAccount')
        .getRecordTypeId(),
      SourceSystemIdentifier = 'TAX-1'
    );
    insert a;
    List<Patient_Need__c> needs = new List<Patient_Need__c>{
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':OFF_CADENCE:1',
        Patient__c = a.Id,
        Rule_Id__c = 'OFF_CADENCE',
        Rule_Version__c = '1',
        Need_Type__c = 'OFF_CADENCE',
        State__c = 'Pending',
        Priority__c = 'Urgent',
        Points__c = 40,
        Next_Action_Date__c = Date.today()
      ),
      new Patient_Need__c(
        Engine_Key__c = a.Id + ':UNENGAGED_30:1',
        Patient__c = a.Id,
        Rule_Id__c = 'UNENGAGED_30',
        Rule_Version__c = '1',
        Need_Type__c = 'UNENGAGED',
        State__c = 'Pending',
        Priority__c = 'Routine',
        Points__c = 20,
        Next_Action_Date__c = Date.today()
      )
    };
    Set<String> keys = OutreachCareItemTaxonomy.parentKeysForNeeds(needs);
    System.assert(keys.contains('OFF_CADENCE'));
    System.assert(!keys.contains('UNENGAGED'), 'Off Cadence suppresses Unengaged');
  }


  @IsTest
  static void clinicalFollowUpFamiliesMapToParentKeys() {
    Assert.areEqual(
      'URGENT_REFERRAL',
      OutreachCareItemTaxonomy.parentKey('URGENT_REFERRAL', 'URGENT_REFERRAL', null)
    );
    Assert.areEqual(
      'MDDO',
      OutreachCareItemTaxonomy.parentKey('MDDO', 'MDDO', null)
    );
    Assert.areEqual(
      'DISCHARGE_TCM',
      OutreachCareItemTaxonomy.parentKey('DISCHARGE_TCM', 'DISCHARGE_TCM', null)
    );
    Assert.areEqual(
      'ADMISSION_TOUCHBASE',
      OutreachCareItemTaxonomy.parentKey(
        'ADMISSION_TOUCHBASE',
        'ADMISSION_TOUCHBASE',
        null
      )
    );
    Assert.areEqual(
      'Urgent referral follow-up',
      OutreachCareItemTaxonomy.parentLabel('URGENT_REFERRAL', null)
    );
    Assert.areEqual(
      'MD/DO visit',
      OutreachCareItemTaxonomy.parentLabel('MDDO', null)
    );
    Assert.areEqual(
      'Discharge TCM',
      OutreachCareItemTaxonomy.parentLabel('DISCHARGE_TCM', null)
    );
    Assert.areEqual(
      'Admission Touchbase',
      OutreachCareItemTaxonomy.parentLabel('ADMISSION_TOUCHBASE', null)
    );

    List<Patient_Need__c> needs = new List<Patient_Need__c>{
      new Patient_Need__c(
        Rule_Id__c = 'AWV_DUE',
        Need_Type__c = 'AWV',
        State__c = 'Pending',
        Shadow__c = false
      ),
      new Patient_Need__c(
        Rule_Id__c = 'NO_NEXT_FOLLOWUP',
        Need_Type__c = 'NO_NEXT',
        State__c = 'Pending',
        Shadow__c = false
      ),
      new Patient_Need__c(
        Rule_Id__c = 'URGENT_REFERRAL',
        Need_Type__c = 'URGENT_REFERRAL',
        State__c = 'Pending',
        Shadow__c = false
      ),
      new Patient_Need__c(
        Rule_Id__c = 'MDDO',
        Need_Type__c = 'MDDO',
        State__c = 'Pending',
        Shadow__c = false
      )
    };
    Set<String> keys = OutreachCareItemTaxonomy.parentKeysForNeeds(needs);
    Assert.isTrue(keys.contains('AWV'));
    Assert.isTrue(keys.contains('NO_NEXT'));
    Assert.isTrue(keys.contains('URGENT_REFERRAL'));
    Assert.isTrue(keys.contains('MDDO'));
  }
}
