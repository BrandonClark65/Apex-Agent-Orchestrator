public with sharing class AgentEngine {

    public static Id runAgent(String agentDeveloperName, String inputContextJson) {

        // 1. Load Agent Definition CMDT
        aao__Agent_Definition__mdt agentDef = [
            SELECT aao__Goal__c,
                   aao__SystemPrompt__c,
                   aao__LLM_Provider__c,
                   aao__MaxSteps__c
            FROM aao__Agent_Definition__mdt
            WHERE DeveloperName = :agentDeveloperName
            LIMIT 1
        ];

        // 2. Create Agent_Run__c record
        Id runId = ExecutionLogger.startRun(
            agentDeveloperName,
            inputContextJson
        );

        try {
            // 3. Build initial LLM request
            LLMRequest req = new LLMRequest();
            req.messages.add(new LLMMessage('system', agentDef.aao__SystemPrompt__c));
            req.messages.add(new LLMMessage('user', inputContextJson));

            // 4. Get LLM client
            LLMClient client = LLMClientFactory.forProvider(agentDef.aao__LLM_Provider__c);

            // 5. Call LLM
            LLMResponse res = client.complete(req);

            // 6. Log step
            ExecutionLogger.logStep(
                runId,
                new AgentStepLog(
                    1,
                    'LLM_Call',
                    JSON.serialize(req),
                    res.rawResponse,
                    null,
                    null,
                    'Completed'
                )
            );

            // 7. Finish run
            ExecutionLogger.finishRun(
                runId,
                res.text,
                'Succeeded',
                null
            );

            return runId;

        } catch (Exception e) {

            ExecutionLogger.finishRun(
                runId,
                null,
                'Failed',
                e.getMessage()
            );

            throw e;
        }
    }
}
