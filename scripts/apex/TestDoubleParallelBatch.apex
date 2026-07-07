// scripts/apex/TestDoubleParallelBatch.apex
// Expected Step Pattern: Steps 1: LLM, 2+3: Tool x2, 4: LLM, 5+6: Tool x2, 7: LLM (final)
Id runId = AgentEngine.runAgent(
    'CRUD_Agent',
    '{"task":"Do this in two parallel rounds. Round 1 (run in parallel): query all Account records in Portland and describe the Account object. Round 2 (after round 1 completes, run in parallel): query all Contact records and describe the Contact object. Summarize everything you found across all four operations."}',
    'Apex'
);

String sqId = '\'' + runId + '\'';
System.debug('Run ID: ' + runId);
System.debug('sf data query --target-org aao --query "SELECT aao__Status__c, aao__PendingToolCount__c, aao__Final_Output__c FROM aao__Agent_Run__c WHERE Id = ' + sqId + '"');
System.debug('sf data query --target-org aao --query "SELECT aao__Step_Number__c, aao__Step_Type__c, aao__Tool__c, aao__Status__c FROM aao__Agent_Step__c WHERE aao__Agent_Run__c = ' + sqId + ' ORDER BY aao__Step_Number__c"');
