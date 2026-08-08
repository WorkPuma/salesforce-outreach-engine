public inherited sharing class OutreachEventService {
    public class EventRequest {
        public Id patientId, episodeId, needId;
        public String eventType, outcome, channel, detail, ruleId, idempotencyKey;
        public Integer attemptNumber;
        public Boolean shadow;
    }
    public class Metrics {
        /** Contact attempt counter (episode Pressure__c / Attempt Count). */
        public Integer attemptCount;
    }

    public static List<Outreach_Event__c> append(List<EventRequest> requests) {
        if (requests == null || requests.isEmpty())
            return new List<Outreach_Event__c>();
        List<Outreach_Event__c> rows = new List<Outreach_Event__c>();
        Set<Id> episodeIds = new Set<Id>();
        for (EventRequest r : requests) {
            if (r == null)
                continue;
            if (r.patientId == null)
                throw new OutreachEventException('Patient is required for outreach event logging.');
            if (String.isBlank(r.eventType))
                throw new OutreachEventException('Event type is required for outreach event logging.');
            if (String.isBlank(r.idempotencyKey))
                throw new OutreachEventException('Idempotency key is required.');
            rows.add(
                new Outreach_Event__c(
                    Patient__c = r.patientId,
                    Episode__c = r.episodeId,
                    Need__c = r.needId,
                    Event_Type__c = r.eventType,
                    Outcome__c = r.outcome,
                    Channel__c = r.channel,
                    Detail__c = r.detail,
                    Rule_Id__c = r.ruleId,
                    Attempt_Number__c = r.attemptNumber,
                    Shadow__c = r.shadow == true,
                    Actor__c = UserInfo.getUserId(),
                    Event_At__c = System.now(),
                    Idempotency_Key__c = r.idempotencyKey
                )
            );
            if (r.episodeId != null)
                episodeIds.add(r.episodeId);
        }
        if (rows.isEmpty())
            return new List<Outreach_Event__c>();
        SObjectAccessDecision decision = Security.stripInaccessible(
            AccessType.CREATABLE,
            rows
        );
        List<Outreach_Event__c> safeRows = (List<Outreach_Event__c>) decision.getRecords();
        if (safeRows.isEmpty())
            throw new OutreachEventException(
                'Outreach Event fields were stripped; create access is required.'
            );
        if (
            !Schema.sObjectType.Outreach_Event__c.isCreateable() ||
            !Schema.sObjectType.Outreach_Event__c.isUpdateable()
        )
            throw new OutreachEventException('Outreach Event write access is required.');
        Database.UpsertResult[] results = Database.upsert(
            safeRows,
            Outreach_Event__c.Idempotency_Key__c,
            false
        );
        List<String> failures = new List<String>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess())
                continue;
            for (Database.Error err : results[i].getErrors())
                failures.add(err.getStatusCode() + ': ' + err.getMessage());
        }
        if (!failures.isEmpty())
            throw new OutreachEventException(
                'Failed to persist outreach event(s): ' + String.join(failures, '; ')
            );
        if (!episodeIds.isEmpty())
            refreshMetrics(episodeIds);
        return safeRows;
    }

    public static void recordNeedLifecycle(
        List<Patient_Need__c> opened,
        List<Patient_Need__c> closed
    ) {
        List<EventRequest> requests = new List<EventRequest>();
        addLifecycle(requests, opened, 'Care Item Opened');
        addLifecycle(requests, closed, 'Care Item Closed');
        append(requests);
    }

    public static Outreach_Event__c record(
        Patient_Need__c need,
        String eventType,
        String outcome,
        String channel,
        String detail,
        Integer attemptNumber,
        String key
    ) {
        EventRequest r = new EventRequest();
        r.patientId = need.Patient__c;
        r.episodeId = need.Episode__c;
        r.needId = need.Id;
        r.ruleId = need.Rule_Id__c;
        r.eventType = eventType;
        r.outcome = outcome;
        r.channel = channel;
        r.detail = detail;
        r.attemptNumber = attemptNumber;
        r.idempotencyKey = key;
        r.shadow = need.Shadow__c;
        List<Outreach_Event__c> saved = append(new List<EventRequest>{ r });
        return saved.isEmpty() ? null : saved[0];
    }

    public static Map<Id, Metrics> calculateMetrics(Set<Id> episodeIds) {
        Map<Id, Metrics> result = new Map<Id, Metrics>();
        for (Id id : episodeIds)
            result.put(id, baseMetrics());
        for (Outreach_Event__c e : [
            SELECT Episode__c, Event_Type__c
            FROM Outreach_Event__c
            WHERE Episode__c IN :episodeIds
            WITH SECURITY_ENFORCED
            ORDER BY Event_At__c ASC
        ]) {
            Metrics m = result.get(e.Episode__c);
            if (e.Event_Type__c == 'Attempt Made')
                m.attemptCount++;
        }
        return result;
    }


    private static void refreshMetrics(Set<Id> episodeIds) {
        Map<Id, Metrics> metrics = calculateMetrics(episodeIds);
        List<Outreach_Episode__c> episodes = new List<Outreach_Episode__c>();
        for (Id id : episodeIds)
            episodes.add(
                new Outreach_Episode__c(
                    Id = id,
                    Pressure__c = metrics.get(id).attemptCount
                )
            );
        if (!episodes.isEmpty()) {
            if (!Schema.sObjectType.Outreach_Episode__c.isUpdateable())
                throw new OutreachEventException('Episode update access is required.');
            update (List<Outreach_Episode__c>) Security.stripInaccessible(
                    AccessType.UPDATABLE,
                    episodes
                )
                .getRecords();
        }
        List<Patient_Outreach_Profile__c> profiles = [
            SELECT Id, Episode__c
            FROM Patient_Outreach_Profile__c
            WHERE Episode__c IN :episodeIds
            WITH SECURITY_ENFORCED
        ];
        for (Patient_Outreach_Profile__c p : profiles) {
            Metrics m = metrics.get(p.Episode__c);
            p.Pressure__c = m.attemptCount;
        }
        if (!profiles.isEmpty()) {
            if (!Schema.sObjectType.Patient_Outreach_Profile__c.isUpdateable())
                throw new OutreachEventException('Profile update access is required.');
            update (List<Patient_Outreach_Profile__c>) Security.stripInaccessible(
                    AccessType.UPDATABLE,
                    profiles
                )
                .getRecords();
        }
    }


    private static void addLifecycle(
        List<EventRequest> target,
        List<Patient_Need__c> needs,
        String type
    ) {
        if (needs == null)
            return;
        Map<String, String> labels = new Map<String, String>();
        for (Outreach_Rule__mdt rule : [
            SELECT Rule_Id__c, Display_Label__c
            FROM Outreach_Rule__mdt
        ]) {
            if (String.isNotBlank(rule.Rule_Id__c))
                labels.put(rule.Rule_Id__c, rule.Display_Label__c);
        }
        for (Patient_Need__c n : needs) {
            EventRequest r = new EventRequest();
            r.patientId = n.Patient__c;
            r.episodeId = n.Episode__c;
            r.needId = n.Id;
            r.ruleId = n.Rule_Id__c;
            r.eventType = type;
            String label = labels.containsKey(n.Rule_Id__c)
                ? labels.get(n.Rule_Id__c)
                : n.Need_Type__c;
            if (type == 'Care Item Opened')
                r.detail = String.isBlank(label)
                    ? 'Care item became active'
                    : label + ' became active';
            else if (type == 'Care Item Closed')
                r.detail = String.isBlank(label)
                    ? 'Care item was closed'
                    : label + ' was closed';
            String legacyType = type == 'Care Item Opened'
                ? 'Need Opened'
                : (type == 'Care Item Closed' ? 'Need Closed' : type);
            r.idempotencyKey =
                n.Engine_Key__c +
                ':' +
                legacyType +
                ':' +
                String.valueOf(Date.today());
            r.shadow = n.Shadow__c;
            target.add(r);
        }
    }

    private static Metrics baseMetrics() {
        Metrics m = new Metrics();
        m.attemptCount = 0;
        return m;
    }

    public class OutreachEventException extends Exception {
    }
}
