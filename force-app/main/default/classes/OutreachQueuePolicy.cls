/**
 * Reads Outreach_Engine_Settings.Default for pressure gating and engagement ranking.
 * Hard gates stay in Apex so queue safety does not depend on RulesEngine availability.
 */
public inherited sharing class OutreachQueuePolicy {
  public class Config {
    public Boolean pressureBlockEnabled;
    public Decimal pressureBlockThreshold;
    public String rankingStrategy;
    public Decimal engagementWeight;
    public Decimal rangeMin;
    public Decimal rangeMax;
    public Integer randomSaltHours;
  }

  @TestVisible
  static Config configOverride;

  public static Config config() {
    if (configOverride != null)
      return configOverride;
    Config c = new Config();
    Outreach_Engine_Settings__mdt row = Outreach_Engine_Settings__mdt.getInstance(
      'Default'
    );
    c.pressureBlockEnabled = row == null
      ? true
      : row.Pressure_Block_Enabled__c == true;
    c.pressureBlockThreshold = row == null || row.Pressure_Block_Threshold__c == null
      ? 80
      : row.Pressure_Block_Threshold__c;
    c.rankingStrategy = row == null || String.isBlank(row.Ranking_Strategy__c)
      ? 'NEUTRAL'
      : row.Ranking_Strategy__c.trim().toUpperCase();
    c.engagementWeight = row == null || row.Engagement_Weight__c == null
      ? 200
      : row.Engagement_Weight__c;
    c.rangeMin = row == null || row.Engagement_Range_Min__c == null
      ? 50
      : row.Engagement_Range_Min__c;
    c.rangeMax = row == null || row.Engagement_Range_Max__c == null
      ? 100
      : row.Engagement_Range_Max__c;
    c.randomSaltHours = row == null || row.Random_Salt_Hours__c == null
      ? 24
      : Math.max(1, row.Random_Salt_Hours__c.intValue());
    return c;
  }

  public static Boolean isPressureBlocked(Decimal pressureScore) {
    Config c = config();
    if (!c.pressureBlockEnabled || pressureScore == null)
      return false;
    return pressureScore >= c.pressureBlockThreshold;
  }
}
