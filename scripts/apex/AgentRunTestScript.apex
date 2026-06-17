Id runId = AgentEngine.runAgent(
    'My_Test_Agent', 
    '{"task": "Find all Accounts in Portland"}'
);

System.debug('Agent Run Id: ' + runId);
