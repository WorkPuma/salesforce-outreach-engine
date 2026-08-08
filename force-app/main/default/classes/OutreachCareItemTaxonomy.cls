/**
 * Shared parent care-item taxonomy for queue KPIs and patient Actions.
 * Collapse Unengaged flavors when Off Cadence is present; ignore Shadow/Inactive cards.
 * Includes clinical follow-up families (referral, MD/DO, discharge, admission) so they
 * render as selectable care-gap cards alongside scheduling parents.
 */
public with sharing class OutreachCareItemTaxonomy {
  public static final Set<String> PARENT_KEYS = new Set<String>{
    'AWV',
    'OFF_CADENCE',
    'NO_NEXT',
    'UNENGAGED',
    'URGENT_REFERRAL',
    'MDDO',
    'DISCHARGE_TCM',
    'ADMISSION_TOUCHBASE'
  };
  public static final Set<String> ACTIVE_NEED_STATES = new Set<String>{
    'Pending',
    'In Progress',
    'Snoozed'
  };

  public static String parentKey(String ruleId, String needType, String family) {
    String rid = ruleId == null ? '' : ruleId.trim().toUpperCase();
    String nt = needType == null ? '' : needType.trim().toUpperCase();
    String fam = family == null ? '' : family.trim().toUpperCase();
    if (rid.contains('AWV') || nt.contains('AWV') || fam == 'AWV')
      return 'AWV';
    if (
      rid == 'OFF_CADENCE' ||
      (nt == 'OFF_CADENCE' && !rid.contains('UNENGAGED'))
    )
      return 'OFF_CADENCE';
    if (rid.startsWith('NO_NEXT') || nt.contains('NO_NEXT') || fam == 'NO_NEXT')
      return 'NO_NEXT';
    if (rid.contains('INACTIVE') || nt.contains('INACTIVE'))
      return 'INACTIVE';
    if (
      rid.contains('UNENGAGED') ||
      nt.contains('UNENGAGED') ||
      fam == 'UNENGAGED'
    )
      return 'UNENGAGED';
    if (
      rid.contains('URGENT_REFERRAL') ||
      nt.contains('URGENT_REFERRAL') ||
      fam == 'URGENT_REFERRAL'
    )
      return 'URGENT_REFERRAL';
    if (rid == 'MDDO' || nt == 'MDDO' || fam == 'MDDO' || rid.contains('MDDO'))
      return 'MDDO';
    if (
      rid.contains('DISCHARGE') ||
      nt.contains('DISCHARGE') ||
      fam == 'DISCHARGE_TCM'
    )
      return 'DISCHARGE_TCM';
    if (
      rid.contains('ADMISSION') ||
      nt.contains('ADMISSION') ||
      fam == 'ADMISSION_TOUCHBASE'
    )
      return 'ADMISSION_TOUCHBASE';
    return String.isNotBlank(fam)
      ? fam
      : (String.isNotBlank(nt) ? nt : rid);
  }

  public static String parentLabel(String key, String fallback) {
    if (key == 'AWV')
      return 'Annual Wellness Visit';
    if (key == 'OFF_CADENCE')
      return 'Off cadence';
    if (key == 'NO_NEXT')
      return 'No next visit';
    if (key == 'UNENGAGED')
      return 'Unengaged';
    if (key == 'INACTIVE')
      return 'Inactive';
    if (key == 'URGENT_REFERRAL')
      return 'Urgent referral follow-up';
    if (key == 'MDDO')
      return 'MD/DO visit';
    if (key == 'DISCHARGE_TCM')
      return 'Discharge TCM';
    if (key == 'ADMISSION_TOUCHBASE')
      return 'Admission Touchbase';
    if (key == 'ACTIVITY')
      return 'Outreach activity';
    return String.isBlank(fallback) ? 'Care item' : fallback;
  }

  /** Distinct parent keys for a patient's active needs (Off Cadence suppresses Unengaged). */
  public static Set<String> parentKeysForNeeds(List<Patient_Need__c> needs) {
    Set<String> keys = new Set<String>();
    Boolean hasOffCadence = false;
    if (needs == null)
      return keys;
    for (Patient_Need__c n : needs) {
      if (n == null || n.Shadow__c == true)
        continue;
      if (n.State__c == 'Superseded' || n.State__c == 'Silenced' || n.State__c == 'Shadow')
        continue;
      if (!ACTIVE_NEED_STATES.contains(n.State__c))
        continue;
      String key = parentKey(n.Rule_Id__c, n.Need_Type__c, null);
      if (key == 'OFF_CADENCE')
        hasOffCadence = true;
      if (PARENT_KEYS.contains(key))
        keys.add(key);
    }
    if (hasOffCadence)
      keys.remove('UNENGAGED');
    keys.remove('INACTIVE');
    return keys;
  }
}
