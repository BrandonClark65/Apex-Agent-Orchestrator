// Real-LLM sanity test for parallel tool execution.
// Run with: sf apex run --file scripts/apex/TestParallelTools.apex --target-org aao
//
// The task is intentionally phrased so that the LLM should recognise two independent
// sub-tasks (query + describe) and respond with {"tools":[...]} rather than two
// sequential single-tool calls.  After the run completes, check the Agent_Step__c
// rows to confirm both tool steps have the same parent run and were logged together.

Id runId = AgentEngine.runAgent(
    'CRUD_Agent',
    '{"task":"Do both of these in parallel: (1) query all Account records and return their names, and (2) describe the fields available on the Account object. Return both results in your final answer."}',
    'Apex'
);

System.debug('Run ID: ' + runId);
System.debug('');
System.debug('Check results with:');
System.debug('  sf data query --target-org aao --query "SELECT Status__c, Final_Output__c, PendingToolCount__c FROM Agent_Run__c WHERE Id = \'' + runId + '\'"');
System.debug('  sf data query --target-org aao --query "SELECT Step_Number__c, Step_Type__c, Tool__c, Status__c FROM Agent_Step__c WHERE Agent_Run__c = \'' + runId + '\' ORDER BY Step_Number__c"');
System.debug('');
System.debug('If parallel execution fired, you should see two ToolCall steps logged in the same run');
System.debug('and PendingToolCount__c = 0 on the Agent_Run__c record once complete.');
