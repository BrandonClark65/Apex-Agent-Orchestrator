public with sharing class AgentEngine {

    //
    // ───────────────────────────────────────────────────────────────
    // 1. PUBLIC ENTRY POINT (SYNCHRONOUS)
    // ───────────────────────────────────────────────────────────────
    //
    @AuraEnabled
    public static Id runAgent(String agentDeveloperName, String inputContextJson, String triggerType) {

        Id runId = ExecutionLogger.startRun(agentDeveloperName, inputContextJson, triggerType);

        // Initial history: we let runLLMStep build the system prompt
        List<LLMMessage> history = new List<LLMMessage>{
            new LLMMessage('user', inputContextJson)
        };

        System.enqueueJob(
            new AgentRunQueueable(agentDeveloperName, inputContextJson, triggerType, runId, history)
        );

        return runId;
    }


    //
    // ───────────────────────────────────────────────────────────────
    // 2. LLM STEP (CALLOUTS ALLOWED)
    //    Called from AgentRunQueueable
    // ───────────────────────────────────────────────────────────────
    //
    public static void runLLMStep(
        String agentDeveloperName,
        String inputContextJson,
        String triggerType,
        Id runId,
        List<LLMMessage> history
    ) {
        System.debug('AgentEngine.runLLMStep: ' + agentDeveloperName + ', runId=' + runId);

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

            // Max step enforcement
            Integer currentStep = ExecutionLogger.getCurrentStep(runId);
            Integer maxSteps = agentDef.aao__MaxSteps__c != null
                ? Integer.valueOf(agentDef.aao__MaxSteps__c)
                : 5;

            if (currentStep >= maxSteps) {
                ExecutionLogger.finishRun(runId, null, 'Failed', 'Max steps exceeded');
                return;
            }

            // Load tools
            Map<String, aao__Agent_Tool_Definition__mdt> toolDefs =
                ToolRegistry.getToolDefinitionsForAgent(agentDeveloperName);

            // Build tool manifest
            String toolManifest = buildToolManifest(toolDefs);

            // Build system prompt
            String systemPrompt =
                agentDef.aao__SystemPrompt__c +
                '\n\nYou have access to the following tools. ' +
                'You may ONLY call tools from this list.\n\n' +
                toolManifest +
                '\n\nAfter receiving a tool_result, you may call another tool OR produce a final answer. ' +
                'Never call the same tool with the same arguments more than once. ';

            // Ensure system message is first
            if (history.isEmpty() || history[0].role != 'system') {
                history.add(0, new LLMMessage('system', systemPrompt));
            }

            // LLM call
            LLMClient client = LLMClientFactory.forProvider(agentDef.aao__LLMProvider__c);
            LLMRequest req = new LLMRequest();
            req.messages = history;

            LLMResponse res = client.complete(req);

            // Log LLM step
            ExecutionLogger.logStep(
                runId,
                new AgentStepLog(
                    ExecutionLogger.nextStepNumber(runId),
                    'LLMCall',
                    JSON.serialize(req),
                    res.rawResponse,
                    null,
                    null,
                    'Completed'
                )
            );

            // Parse response
            Map<String, Object> parsed = (Map<String, Object>)JSON.deserializeUntyped(res.text);

            // Final answer
            if (parsed.containsKey('final')) {
                Object finalOutput = parsed.get('final');
                String finalAnswer = JSON.serialize(finalOutput);
                ExecutionLogger.finishRun(runId, finalAnswer, 'Succeeded', null);
                return;
            }

            // Tool call
            if (parsed.containsKey('tool')) {
                String toolName = (String)parsed.get('tool');
                Map<String, Object> args = (Map<String, Object>)parsed.get('args');

                // Prevent repeated identical tool calls
                if (ExecutionLogger.hasIdenticalToolCall(runId, toolName, args)) {
                    ExecutionLogger.finishRun(
                        runId,
                        null,
                        'Failed',
                        'Repeated identical tool call detected.'
                    );
                    return;
                }

                // Enqueue tool step
                System.enqueueJob(
                    new AgentToolQueueable(
                        agentDeveloperName,
                        triggerType,
                        runId,
                        history,
                        toolName,
                        args
                    )
                );
                return;
            }

            // Unexpected response
            ExecutionLogger.finishRun(runId, res.rawResponse, 'Failed', 'Invalid LLM response');

        } catch (Exception e) {
            ExecutionLogger.finishRun(runId, null, 'Failed', e.getMessage());
        }
    }



    //
    // ───────────────────────────────────────────────────────────────
    // 3. TOOL STEP (DML ALLOWED, NO CALLOUTS)
    //    Called from AgentToolQueueable
    // ───────────────────────────────────────────────────────────────
    //
    public static void runToolStep(
        String agentDeveloperName,
        String triggerType,
        Id runId,
        List<LLMMessage> history,
        String toolName,
        Map<String, Object> args
    ) {
        System.debug('AgentEngine.runToolStep: ' + toolName + ', runId=' + runId);

        try {
            // Load tool definitions
            Map<String, aao__Agent_Tool_Definition__mdt> toolDefs =
                ToolRegistry.getToolDefinitionsForAgent(agentDeveloperName);

            if (!toolDefs.containsKey(toolName)) {
                ExecutionLogger.finishRun(runId, null, 'Failed', 'Invalid tool: ' + toolName);
                return;
            }

            // Load tool class
            aao__Agent_Tool_Definition__mdt def = toolDefs.get(toolName);
            AgentTool tool = ToolRegistry.getToolByClassName(def.aao__Tool_Class__c);

            // Execute tool
            AgentToolResult toolResult = tool.run(args);

            // Log tool step
            ExecutionLogger.logStep(
                runId,
                new AgentStepLog(
                    ExecutionLogger.nextStepNumber(runId),
                    'ToolCall',
                    null,
                    null,
                    JSON.serialize(args),
                    JSON.serialize(toolResult),
                    toolResult.success ? 'Completed' : 'Failed'
                )
            );

            //
            // Add structured tool_result message
            //
            history.add(new LLMMessage(
                'assistant',
                '{"tool_result": {"tool": "' + toolName + '", "output": ' + JSON.serialize(toolResult) + '}}'
            ));

            //
            // Add explicit instruction for next step
            //
            history.add(new LLMMessage(
                'user',
                '{"instruction": "Use the tool_result above. If more tools are needed, call them. ' +
                'Otherwise, return a final answer. Always respond in the required JSON format."}'
            ));

            //
            // Schedule next LLM step
            //
            System.enqueueJob(
                new AgentRunQueueable(
                    agentDeveloperName,
                    null,
                    triggerType,
                    runId,
                    history
                )
            );

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
