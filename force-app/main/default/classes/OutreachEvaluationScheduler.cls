global without sharing class OutreachEvaluationScheduler implements Schedulable {
    global void execute(SchedulableContext context){
        Integer size = 100;
        if (OutreachRulesEngineClient.isEnabled()) {
            size = OutreachRulesEngineClient.settings().batchSize;
        }
        Database.executeBatch(new OutreachEvaluationBatch(), size);
    }
}
