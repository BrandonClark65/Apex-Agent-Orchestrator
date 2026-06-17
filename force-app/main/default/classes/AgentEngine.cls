public with sharing class AgentEngine {

    public static Id runAgent(String agentDeveloperName, String inputContextJson) {

        aao__Agent_Definition__mdt agentDef = [
            SELECT aao__Goal__c,
                   aao__SystemPrompt__c,
                   aao__LLM_Provider__c,
                   aao__MaxSteps__c
            FROM aao__Agent_Definition__mdt
            WHERE DeveloperName = :agentDeveloperName
            LIMIT 1
        ];

        Id runId = ExecutionLogger.startRun(agentDeveloperName, inputContextJson);

        try {
            LLMClient client = LLMClientFactory.forProvider(agentDef.aao__LLM_Provider__c);

            List<LLMMessage> history = new List<LLMMessage>{
                new LLMMessage('system', agentDef.aao__SystemPrompt__c),
                new LLMMessage('user', inputContextJson)
            };

            Decimal maxSteps = agentDef.aao__MaxSteps__c != null ? agentDef.aao__MaxSteps__c : 5;

            for (Integer step = 1; step <= maxSteps; step++) {

                // 1. Call LLM
                LLMRequest req = new LLMRequest();
                req.messages = history;

                LLMResponse res = client.complete(req);

                // Log LLM step
                ExecutionLogger.logStep(
                    runId,
                    new AgentStepLog(
                        step,
                        'LLM_Call',
                        JSON.serialize(req),
                        res.rawResponse,
                        null,
                        null,
                        'Completed'
                    )
                );

                // 2. Parse LLM response
                Map<String, Object> parsed = (Map<String, Object>)JSON.deserializeUntyped(res.text);

                if (parsed.containsKey('tool')) {
                    // Tool call
                    String toolName = (String)parsed.get('tool');
                    Map<String, Object> args = (Map<String, Object>)parsed.get('args');

                    AgentTool tool = ToolRegistry.getToolByClassName(toolName);
                    AgentToolResult toolResult = tool.run(args);

                    // Log tool step
                    ExecutionLogger.logStep(
                        runId,
                        new AgentStepLog(
                            step,
                            'ToolCall',
                            null,
                            null,
                            JSON.serialize(args),
                            JSON.serialize(toolResult),
                            toolResult.success ? 'Completed' : 'Failed'
                        )
                    );

                    // Feed tool result back into LLM
                    history.add(new LLMMessage('assistant', JSON.serialize(toolResult)));
                    continue;
                }

                // 3. Final answer
                if (parsed.containsKey('final')) {
                    String finalAnswer = (String)parsed.get('final');

                    ExecutionLogger.finishRun(runId, finalAnswer, 'Succeeded', null);
                    return runId;
                }

                // If no tool and no final, treat as final
                ExecutionLogger.finishRun(runId, res.text, 'Succeeded', null);
                return runId;
            }

            ExecutionLogger.finishRun(runId, null, 'Failed', 'Max steps exceeded');
            return runId;

        } catch (Exception e) {
            ExecutionLogger.finishRun(runId, null, 'Failed', e.getMessage());
            throw e;
        }
    }
}
