/**
 * Encodes Unclaimed queue sort key (lower = higher priority).
 * bucket(STAT/Urgent/Routine) + blended(points, engagement strategy) + due date.
 */
public class OutreachRoutingPriority {
  public static Integer calculate(
    String priority,
    Decimal points,
    Date dueDate
  ) {
    return calculate(priority, points, dueDate, null, null);
  }

  public static Integer calculate(
    String priority,
    Decimal points,
    Date dueDate,
    Decimal engagementScore,
    Id patientId
  ) {
    Integer bucket = priority == 'STAT' ? 0 : priority == 'Urgent' ? 1 : 2;
    Decimal basePts = points == null ? 0 : points;
    Decimal boost = engagementBoost(engagementScore, patientId);
    Integer score = Integer.valueOf(
      clamp(basePts + boost, 0, 9999).setScale(0, System.RoundingMode.HALF_UP)
    );
    Integer due = dueDate == null
      ? 9999
      : Date.newInstance(2000, 1, 1).daysBetween(dueDate);
    due = Math.max(0, Math.min(9999, due));
    return bucket * 100000000 + (9999 - score) * 10000 + due;
  }

  @TestVisible
  static Decimal engagementBoost(Decimal engagementScore, Id patientId) {
    OutreachQueuePolicy.Config c = OutreachQueuePolicy.config();
    String strategy = c.rankingStrategy;
    if (strategy == 'NEUTRAL' || String.isBlank(strategy))
      return 0;
    Decimal weight = c.engagementWeight == null ? 0 : c.engagementWeight;
    if (weight <= 0)
      return 0;
    Decimal eng = engagementScore == null ? 0 : engagementScore;
    // Map -100..100 → 0..1
    Decimal norm = clamp((eng + 100) / 200, 0, 1);

    if (strategy == 'HIGH')
      return weight * norm;
    if (strategy == 'LOW')
      return weight * (1 - norm);
    if (strategy == 'RANGE') {
      Decimal lo = c.rangeMin == null ? -100 : c.rangeMin;
      Decimal hi = c.rangeMax == null ? 100 : c.rangeMax;
      if (eng < lo || eng > hi)
        return 0;
      return weight * norm;
    }
    if (strategy == 'RANDOM') {
      Integer saltHours = c.randomSaltHours == null ? 24 : c.randomSaltHours;
      Long bucket = System.currentTimeMillis() / (saltHours * 3600000L);
      String key =
        String.valueOf(patientId) +
        ':' +
        String.valueOf(bucket);
      Integer h = Math.abs(key.hashCode());
      return weight * (Decimal.valueOf(Math.mod(h, 10001)) / 10000);
    }
    return 0;
  }

  private static Decimal clamp(Decimal v, Decimal lo, Decimal hi) {
    if (v == null)
      return lo;
    if (v < lo)
      return lo;
    if (v > hi)
      return hi;
    return v;
  }
}
