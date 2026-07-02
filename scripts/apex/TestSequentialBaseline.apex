// scripts/apex/TestSequentialBaseline.apex
// Expected Step Pattern: Steps alternate LLM->Tool->LLM->Tool->LLM — no paired tools
Id runId = AgentEngine.runAgent(
    'CRUD_Agent',
    '{"task":"Query all Account records, return their names. Then describe the Account object fields. Do these one at a time, not in parallel."}',
    'Apex'
);

String sqId = '\'' + runId + '\'';
System.debug('Run ID: ' + runId);
System.debug('sf data query --target-org aao --query "SELECT aao__Status__c, aao__PendingToolCount__c, aao__Final_Output__c FROM aao__Agent_Run__c WHERE Id = ' + sqId + '"');
System.debug('sf data query --target-org aao --query "SELECT aao__Step_Number__c, aao__Step_Type__c, aao__Tool__c, aao__Status__c FROM aao__Agent_Step__c WHERE aao__Agent_Run__c = ' + sqId + ' ORDER BY aao__Step_Number__c"');
