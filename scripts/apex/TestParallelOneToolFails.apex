// scripts/apex/TestParallelOneToolFails.apex
// Expected Step Pattern: Steps 1: LLM, 2+3: Tool (Completed) + Tool (Failed), 4: LLM (final)
// Verifies that completeParallelToolStep error path still decrements PendingToolCount__c
// to 0 and allows the LLM to finalize even when one parallel tool fails.
Id runId = AgentEngine.runAgent(
    'CRUD_Agent',
    '{"task":"In parallel: (1) query all Account records and return their names, and (2) query all records from the object called FakeObject__c and return the results. Include both results (or any errors) in your final answer."}',
    'Apex'
);

String sqId = '\'' + runId + '\'';
System.debug('Run ID: ' + runId);
System.debug('sf data query --target-org aao --query "SELECT aao__Status__c, aao__PendingToolCount__c, aao__Final_Output__c FROM aao__Agent_Run__c WHERE Id = ' + sqId + '"');
System.debug('sf data query --target-org aao --query "SELECT aao__Step_Number__c, aao__Step_Type__c, aao__Tool__c, aao__Status__c FROM aao__Agent_Step__c WHERE aao__Agent_Run__c = ' + sqId + ' ORDER BY aao__Step_Number__c"');
