# Salesforce outreach engine

Patient outreach automation for Salesforce Health Cloud. Evaluates patient needs against configurable rules, creates outreach episodes, tracks engagement, and routes work to agents across phone, SMS, email, and portal channels.

This is a de-identified extraction from a production healthcare Salesforce org. All organization names, endpoints, credentials, and identifiers have been replaced with generic placeholders.

## What it does

The engine runs a nightly batch that evaluates every patient against a rule set (AWV due, off-cadence, no next appointment, unengaged for 12+ months, etc.). Patients who match get an outreach episode with a priority score, pressure gate, and engagement level. Episodes route to agents via Omni-Channel or get queued for automated communication.

## How it fits together

```
OutreachEvaluationBatch
  -> OutreachRuleEvaluator (checks rules against patient state)
  -> OutreachEpisodePlanner (creates episodes, assigns priority)
  -> OutreachQueueService (queues for agent or automated action)
  -> OutreachOmniRoutingService (routes to Omni-Channel)
  -> OutreachEventService (logs every attempt and outcome)
```

The RulesEngine client bridges to an external rules engine via Named Credentials for advanced decisioning. A reconciliation batch ties outreach outcomes back to evidence (appointments booked, labs ordered, etc.).

## Custom objects

| Object | Type | Purpose |
|--------|------|---------|
| `Outreach_Episode__c` | Custom | Active outreach episode for a patient |
| `Outreach_Event__c` | Custom | Individual outreach attempt |
| `Outreach_Evidence_Link__c` | Custom | Links outreach to reconciled evidence |
| `Patient_Outreach_Profile__c` | Custom | Patient-level outreach summary |
| `Outreach_Rule__mdt` | Metadata | Configurable outreach rules |
| `Outreach_Call_Result__mdt` | Metadata | Call result outcomes catalog |
| `Outreach_Channel__mdt` | Metadata | Communication channels |
| `Outreach_Engine_Settings__mdt` | Metadata | Engine configuration |

## LWC components

- `outreachConfiguration` admin config panel
- `outreachWorkbench` agent workbench for processing
- `patientContextCard` patient context display
- `patientOutreachActions` action buttons for outcomes
- `patientOutreachOutcome` outcome logging
- `patientOutreachPanel` full outreach panel with history

## Built with

Salesforce Health Cloud, PlatformAI GenAI (prompt templates for next-action rationale), and Lightning Web Components.

## License

MIT
