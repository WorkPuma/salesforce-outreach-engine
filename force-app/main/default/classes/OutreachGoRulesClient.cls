public inherited sharing class OutreachRulesEngineClient {
  public class RulesEngineException extends Exception {
  }

  public class Settings {
    public Boolean enabled;
    public String projectSlug;
    public String surfaceKey;
    public String reactionKey;
    public String namedCredential;
    public Integer batchSize;
  }

  public class SurfaceHit {
    public Boolean eligible;
    public String ruleId;
    public String family;
    public String needType;
    public String category;
    public String priority;
    public Decimal points;
    public Boolean shadowOnly;
    public Boolean createWork;
    public String scheduleBoundType;
    public String scheduleEarliest;
    public String scheduleLatest;
    public Integer scheduleLatestOffsetDays;
    public String schedulePhrase;
    public String statusLabel;
  }

  public class ReactionResult {
    public Integer suppressDays;
    public Integer snoozeDays;
    public Boolean resolve;
    public String suppressFamily;
    public String reason;
  }

  @TestVisible
  static Settings settingsOverride;
  @TestVisible
  static String mockSurfaceJson;
  @TestVisible
  static String mockReactionJson;

  public static Settings settings() {
    if (settingsOverride != null)
      return settingsOverride;
    Outreach_RulesEngine_Settings__mdt row = Outreach_RulesEngine_Settings__mdt.getInstance(
      'Default'
    );
    Settings s = new Settings();
    if (row == null) {
      s.enabled = false;
      s.projectSlug = 'patient-outreach';
      s.surfaceKey = 'outreach-surface';
      s.reactionKey = 'outreach-reaction';
      s.namedCredential = 'RulesEngine_Agent';
      s.batchSize = 20;
      return s;
    }
    s.enabled = row.Enabled__c == true;
    s.projectSlug = String.isBlank(row.Project_Slug__c)
      ? 'patient-outreach'
      : row.Project_Slug__c;
    s.surfaceKey = String.isBlank(row.Surface_Decision_Key__c)
      ? 'outreach-surface'
      : row.Surface_Decision_Key__c;
    s.reactionKey = String.isBlank(row.Reaction_Decision_Key__c)
      ? 'outreach-reaction'
      : row.Reaction_Decision_Key__c;
    s.namedCredential = String.isBlank(row.Named_Credential__c)
      ? 'RulesEngine_Agent'
      : row.Named_Credential__c;
    s.batchSize = row.Batch_Size__c == null
      ? 20
      : Math.max(1, row.Batch_Size__c.intValue());
    return s;
  }

  public static Boolean isEnabled() {
    return settings().enabled == true;
  }

  public static List<SurfaceHit> evaluateSurface(Map<String, Object> context) {
    Settings s = settings();
    Object raw = evaluate(s.projectSlug, s.surfaceKey, context, mockSurfaceJson);
    return parseSurfaceHits(raw);
  }

  public static ReactionResult evaluateReaction(Map<String, Object> context) {
    Settings s = settings();
    Object raw = evaluate(s.projectSlug, s.reactionKey, context, mockReactionJson);
    return parseReaction(raw);
  }

  @TestVisible
  static Object evaluate(
    String project,
    String key,
    Map<String, Object> context,
    String mockBody
  ) {
    if (mockBody != null)
      return unwrapResult(JSON.deserializeUntyped(mockBody));
    Settings s = settings();
    HttpRequest req = new HttpRequest();
    String path =
      '/api/projects/' +
      EncodingUtil.urlEncode(project, 'UTF-8') +
      '/evaluate/' +
      EncodingUtil.urlEncode(key, 'UTF-8');
    req.setEndpoint('callout:' + s.namedCredential + path);
    req.setMethod('POST');
    req.setHeader('Content-Type', 'application/json');
    req.setTimeout(12000);
    Map<String, Object> body = new Map<String, Object>{
      'context' => context == null ? new Map<String, Object>() : context,
      'trace' => false
    };
    req.setBody(JSON.serialize(body));
    HttpResponse res = new Http().send(req);
    if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
      throw new RulesEngineException(
        'RulesEngine evaluate HTTP ' + res.getStatusCode() + ': ' + res.getBody()
      );
    }
    return unwrapResult(JSON.deserializeUntyped(res.getBody()));
  }

  @TestVisible
  static Object unwrapResult(Object parsed) {
    if (parsed instanceof Map<String, Object>) {
      Map<String, Object> m = (Map<String, Object>) parsed;
      if (m.containsKey('result'))
        return m.get('result');
    }
    return parsed;
  }

  @TestVisible
  static List<SurfaceHit> parseSurfaceHits(Object raw) {
    List<SurfaceHit> hits = new List<SurfaceHit>();
    List<Object> rows;
    if (raw instanceof List<Object>)
      rows = (List<Object>) raw;
    else if (raw instanceof Map<String, Object>)
      rows = new List<Object>{ raw };
    else
      return hits;
    for (Object rowObj : rows) {
      if (!(rowObj instanceof Map<String, Object>))
        continue;
      Map<String, Object> row = (Map<String, Object>) rowObj;
      SurfaceHit h = new SurfaceHit();
      h.eligible = toBool(row.get('eligible'), true);
      h.ruleId = toStr(row.get('ruleId'));
      h.family = toStr(row.get('family'));
      h.needType = toStr(row.get('needType'));
      h.category = toStr(row.get('category'));
      h.priority = toStr(row.get('priority'));
      h.points = toDec(row.get('points'));
      h.shadowOnly = toBool(row.get('shadowOnly'), false);
      h.createWork = toBool(row.get('createWork'), true);
      h.scheduleBoundType = toStr(row.get('scheduleBoundType'));
      h.scheduleEarliest = toStr(row.get('scheduleEarliest'));
      h.scheduleLatest = toStr(row.get('scheduleLatest'));
      Object offsetRaw = row.get('scheduleLatestOffsetDays');
      h.scheduleLatestOffsetDays = offsetRaw == null
        ? null
        : toInt(offsetRaw, 0);
      h.schedulePhrase = toStr(row.get('schedulePhrase'));
      h.statusLabel = toStr(row.get('statusLabel'));
      if (h.eligible == true && String.isNotBlank(h.ruleId))
        hits.add(h);
    }
    return hits;
  }

  @TestVisible
  static ReactionResult parseReaction(Object raw) {
    ReactionResult r = new ReactionResult();
    r.suppressDays = 0;
    r.snoozeDays = 0;
    r.resolve = false;
    if (raw instanceof List<Object>) {
      List<Object> rows = (List<Object>) raw;
      if (!rows.isEmpty())
        raw = rows[0];
    }
    if (!(raw instanceof Map<String, Object>))
      return r;
    Map<String, Object> row = (Map<String, Object>) raw;
    r.suppressDays = toInt(row.get('suppressDays'), 0);
    r.snoozeDays = toInt(row.get('snoozeDays'), 0);
    r.resolve = toBool(row.get('resolve'), false);
    r.suppressFamily = toStr(row.get('suppressFamily'));
    r.reason = toStr(row.get('reason'));
    return r;
  }

  static Boolean toBool(Object v, Boolean dflt) {
    if (v == null)
      return dflt;
    if (v instanceof Boolean)
      return (Boolean) v;
    return String.valueOf(v).toLowerCase() == 'true';
  }
  static String toStr(Object v) {
    return v == null ? null : String.valueOf(v);
  }
  static Decimal toDec(Object v) {
    if (v == null)
      return null;
    if (v instanceof Decimal)
      return (Decimal) v;
    return Decimal.valueOf(String.valueOf(v));
  }
  static Integer toInt(Object v, Integer dflt) {
    if (v == null)
      return dflt;
    if (v instanceof Integer)
      return (Integer) v;
    if (v instanceof Decimal)
      return ((Decimal) v).intValue();
    return Integer.valueOf(String.valueOf(v));
  }
}
