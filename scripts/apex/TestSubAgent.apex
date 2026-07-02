// Real-LLM end-to-end test for multi-agent collaboration (SubAgentTool).
// Run with: sf apex run --file scripts/apex/TestSubAgent.apex --target-org aao
//
// Starts an Orchestrator_Agent run whose task is phrased so the LLM should delegate
// to CRUD_Agent via SubAgentTool. Expected sequence:
//   1. Parent LLM step returns {"tool":"SubAgentTool", ...}
//   2. Parent's ToolCall step is logged with Status__c = 'Pending' and the parent suspends
//   3. A child Agent_Run__c appears with Parent_Run__c = parent, Depth__c = 1,
//      Trigger_Type__c = 'SubAgent', and runs the query itself
//   4. When the child finishes, the parent's Pending step flips to Completed/Failed,
//      the child's final output lands in the parent's history, and the parent finalizes.

Id runId = AgentEngine.runAgent(
  'Orchestrator_Agent',
  '{"task":"Use SubAgentTool to delegate this task to the agent named CRUD_Agent: query all Account records and report how many exist and list their names. When the sub-agent returns, summarize its findings in your final answer."}',
  'Apex'
);

System.debug('Parent Run ID: ' + runId);
System.debug('');
System.debug('The run is async — give it ~30-60 seconds, then check results with:');
System.debug('');
System.debug('Parent run (expect Status Succeeded, final output summarizing accounts):');
System.debug('  sf data query --target-org aao --query "SELECT aao__Status__c, aao__Final_Output__c, aao__Error_Message__c, aao__PendingToolCount__c FROM aao__Agent_Run__c WHERE Id = \'' + runId + '\'"');
System.debug('');
System.debug('Parent steps (expect the SubAgentTool ToolCall step Completed — it is Pending while the child runs):');
System.debug('  sf data query --target-org aao --query "SELECT aao__Step_Number__c, aao__Step_Type__c, aao__Tool__c, aao__Status__c FROM aao__Agent_Step__c WHERE aao__Agent_Run__c = \'' + runId + '\' ORDER BY aao__Step_Number__c"');
System.debug('');
System.debug('Child run (expect one row: Agent CRUD_Agent, Trigger_Type SubAgent, Depth 1, Status Succeeded):');
System.debug('  sf data query --target-org aao --query "SELECT Id, aao__Agent__c, aao__Status__c, aao__Trigger_Type__c, aao__Depth__c, aao__Final_Output__c FROM aao__Agent_Run__c WHERE aao__Parent_Run__c = \'' + runId + '\'"');
System.debug('');
System.debug('Child steps (replace <childRunId> from the query above):');
System.debug('  sf data query --target-org aao --query "SELECT aao__Step_Number__c, aao__Step_Type__c, aao__Tool__c, aao__Status__c FROM aao__Agent_Step__c WHERE aao__Agent_Run__c = \'<childRunId>\' ORDER BY aao__Step_Number__c"');
