// scripts/apex/TestParallelThenSequential.apex
// Expected Step Pattern: Steps 1: LLM, 2+3: 2x Tool, 4: LLM, 5: Tool, 6: LLM (final)
Id runId = AgentEngine.runAgent(
    'CRUD_Agent',
    '{"task":"First, in parallel: (1) query all Account records returning Id and Name, and (2) describe the Contact object fields. Then, using those results, query Contacts that are linked to any of the accounts you found and return their names and email addresses."}',
    'Apex'
);

String sqId = '\'' + runId + '\'';
System.debug('Run ID: ' + runId);
System.debug('sf data query --target-org aao --query "SELECT aao__Status__c, aao__PendingToolCount__c, aao__Final_Output__c FROM aao__Agent_Run__c WHERE Id = ' + sqId + '"');
System.debug('sf data query --target-org aao --query "SELECT aao__Step_Number__c, aao__Step_Type__c, aao__Tool__c, aao__Status__c FROM aao__Agent_Step__c WHERE aao__Agent_Run__c = ' + sqId + ' ORDER BY aao__Step_Number__c"');
