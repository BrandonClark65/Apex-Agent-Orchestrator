public with sharing class AgentEngine {

    //
    // ───────────────────────────────────────────────────────────────
    // 1. PUBLIC ENTRY POINT (SYNCHRONOUS)
    // ───────────────────────────────────────────────────────────────
    //
    @AuraEnabled
    public static Id runAgent(String agentDeveloperName, String inputContextJson, String triggerType) {

        Id runId = ExecutionLogger.startRun(agentDeveloperName, inputContextJson, triggerType);

        System.enqueueJob(
            new AgentRunQueueable(agentDeveloperName, inputContextJson, triggerType, runId)
        );

        return runId;
    }


    //
    // ───────────────────────────────────────────────────────────────
    // 2. ASYNC EXECUTION (CALLOUTS ALLOWED)
    // ───────────────────────────────────────────────────────────────
    //
    public void executeAgentRun(String agentDeveloperName, String inputContextJson, String triggerType, Id runId) {
        System.debug('Executing agent run: ' + agentDeveloperName + ', ' + inputContextJson + ', ' + triggerType + ', ' + runId);

        try {
            // Load agent definition
            aao__Agent_Definition__mdt agentDef = [
                SELECT aao__Goal__c,
                       aao__SystemPrompt__c,
                       aao__LLMProvider__c,
                       aao__MaxSteps__c
                FROM aao__Agent_Definition__mdt
                WHERE DeveloperName = :agentDeveloperName
                LIMIT 1
            ];

            // Load allowed tools for this agent
            Map<String, aao__Agent_Tool_Definition__mdt> toolDefs = ToolRegistry.getToolDefinitionsForAgent(agentDeveloperName);
            System.debug('Loaded tool definitions: ' + toolDefs);

            // Build tool manifest
            String toolManifest = buildToolManifest(toolDefs);
            System.debug('Built tool manifest: ' + toolManifest);

            // Build enhanced System prompt
            String systemPrompt =
                agentDef.aao__SystemPrompt__c +
                '\n\nYou have access to the following tools. ' +
                'You may ONLY call tools from this list.\n\n' +
                toolManifest;

            // Build LLM client
            LLMClient client = LLMClientFactory.forProvider(agentDef.aao__LLMProvider__c);

            // Build initial history
            List<LLMMessage> history = new List<LLMMessage>{
                new LLMMessage('system', systemPrompt),
                new LLMMessage('user', inputContextJson)
            };

            Decimal maxSteps = agentDef.aao__MaxSteps__c != null ? agentDef.aao__MaxSteps__c : 5;


            //
            // ───────────────────────────────────────────────────────────────
            // MAIN AGENT LOOP
            // ───────────────────────────────────────────────────────────────
            //
            for (Integer step = 1; step <= maxSteps; step++) {

                // 1. Call LLM
                LLMRequest req = new LLMRequest();
                req.messages = history;
                System.debug('LLM Request step ' + step + ': ' + JSON.serialize(req));

                LLMResponse res = client.complete(req);

                // Log LLM step
                ExecutionLogger.logStep(
                    runId,
                    new AgentStepLog(
                        step,
                        'LLMCall',
                        JSON.serialize(req),
                        res.rawResponse,
                        null,
                        null,
                        'Completed'
                    )
                );

                // 2. Parse LLM response
                Map<String, Object> parsed = (Map<String, Object>)JSON.deserializeUntyped(res.text);

                //
                // ───────────────────────────────────────────────────────────────
                // TOOL CALL
                // ───────────────────────────────────────────────────────────────
                //
                if (parsed.containsKey('tool')) {
                    System.debug('LLM wants to call a tool with args: ' + JSON.serialize(parsed));

                    String toolName = (String)parsed.get('tool');
                    Map<String, Object> args = (Map<String, Object>)parsed.get('args');
                    System.debug('Parsed tool call: ' + toolName + ' with args: ' + JSON.serialize(args));

                    // Guardrail: invalid tool
                    if (!toolDefs.containsKey(toolName)) {
                        System.debug('LLM attempted to call invalid tool: ' + toolName);

                        String errorMsg = 'Invalid tool "' + toolName + '". ' +
                                          'You may ONLY call tools listed in the System prompt.';

                        // Log invalid tool step
                        ExecutionLogger.logStep(
                            runId,
                            new AgentStepLog(
                                step,
                                'InvalidTool',
                                null,
                                null,
                                JSON.serialize(args),
                                errorMsg,
                                'Failed'
                            )
                        );

                        // Tell LLM it used an invalid tool
                        System.debug('Telling LLM about invalid tool usage: ' + errorMsg);
                        history.add(new LLMMessage('assistant', '{"error": "' + errorMsg + '"}'));
                        continue;
                    }

                    // Valid tool → execute
                    AgentTool tool = ToolRegistry.getToolByClassName(toolDefs.get(toolName).aao__Tool_Class__c);
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


                //
                // ───────────────────────────────────────────────────────────────
                // FINAL ANSWER
                // ───────────────────────────────────────────────────────────────
                //
                if (parsed.containsKey('final')) {
                    String finalAnswer = (String)parsed.get('final');
                    ExecutionLogger.finishRun(runId, finalAnswer, 'Succeeded', null);
                    return;
                }

                // If no tool and no final, treat as final
                ExecutionLogger.finishRun(runId, res.text, 'Succeeded', null);
                return;
            }

            // Max steps exceeded
            ExecutionLogger.finishRun(runId, null, 'Failed', 'Max steps exceeded');

        } catch (Exception e) {
            ExecutionLogger.finishRun(runId, null, 'Failed', e.getMessage());
        }
    }


    //
    // ───────────────────────────────────────────────────────────────
    // TOOL MANIFEST BUILDER
    // ───────────────────────────────────────────────────────────────
    //
    private static String buildToolManifest(Map<String, aao__Agent_Tool_Definition__mdt> toolDefs) {
        String manifest = '[\n';
        for (aao__Agent_Tool_Definition__mdt def : toolDefs.values()) {
            manifest += '  {\n' +
                '    "name": "' + def.DeveloperName + '",\n' +
                '    "description": "' + def.aao__Description__c + '",\n' +
                '    "input_schema": ' + def.aao__InputSchema__c + ',\n' +
                '    "output_schema": ' + def.aao__OutputSchema__c + '\n' +
                '  },\n';
        }
        manifest += ']';
        return manifest;
    }
}
