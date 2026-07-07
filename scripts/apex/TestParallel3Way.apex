// scripts/apex/TestParallel3Way.apex
// Expected Step Pattern: Step 1: LLMCall, Steps 2/3/4: 3x ToolCall, Step 5: LLMCall (final)
Id runId = AgentEngine.runAgent(
    'CRUD_Agent',
    '{"task":"Do all three of these in parallel and report every result: (1) query all Account records from Portland and return their names, (2) describe the fields on the Contact object, (3) Return all Contact records."}',
    'Apex'
);

String sqId = '\'' + runId + '\'';
System.debug('Run ID: ' + runId);
System.debug('sf data query --target-org aao --query "SELECT aao__Status__c, aao__PendingToolCount__c FROM aao__Agent_Run__c WHERE Id = ' + sqId + '"');
System.debug('sf data query --target-org aao --query "SELECT aao__Step_Number__c, aao__Step_Type__c, aao__Tool__c, aao__Status__c FROM aao__Agent_Step__c WHERE aao__Agent_Run__c = ' + sqId + ' ORDER BY aao__Step_Number__c"');
