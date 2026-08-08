global without sharing class OutreachEvaluationBatch implements Database.Batchable<SObject>, Database.AllowsCallouts {
    private Set<Id> cohortIds;
    global OutreachEvaluationBatch(){this.cohortIds=null;}
    global OutreachEvaluationBatch(Set<Id> cohortIds){
        if(cohortIds!=null&&cohortIds.size()>2000)throw new OutreachBatchException('Targeted cohort is limited to 2,000 Accounts.');
        this.cohortIds=cohortIds;
    }
    global Database.QueryLocator start(Database.BatchableContext context){
        if(cohortIds!=null)return Database.getQueryLocator([SELECT Id FROM Account WHERE Id IN :cohortIds AND IsPersonAccount=true]);
        return Database.getQueryLocator([SELECT Id FROM Account WHERE IsPersonAccount=true
            AND Total_Appointment_Number__c>0]);
    }
    global void execute(Database.BatchableContext context,List<SObject> scope){
        Set<Id> ids=new Set<Id>();for(SObject row:scope)ids.add(row.Id);
        // Case cutover: evaluate + plan only — no LegacyCaseAdapter.reconcile
        OutreachRuleEvaluator.evaluate(ids);
        OutreachEpisodePlanner.plan(ids);
    }
    global void finish(Database.BatchableContext context){}
    public static void evaluateTargeted(Set<Id> accountIds){
        if(accountIds==null||accountIds.isEmpty())return;
        if(accountIds.size()>200)throw new OutreachBatchException('Synchronous evaluation is limited to 200 Accounts.');
        OutreachRuleEvaluator.evaluate(accountIds);
        OutreachEpisodePlanner.plan(accountIds);
    }
    public class OutreachBatchException extends Exception{}
}
