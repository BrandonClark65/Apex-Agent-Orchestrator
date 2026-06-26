public with sharing class AgentEngine {

    //
    // ───────────────────────────────────────────────────────────────
    // 1. PUBLIC ENTRY POINT
    // ───────────────────────────────────────────────────────────────
    //
    @AuraEnabled
    public static Id runAgent(String agentDeveloperName, String inputContextJson, String triggerType) {

        Id runId = ExecutionLogger.startRun(agentDeveloperName, inputContextJson, triggerType);

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
    // ───────────────────────────────────────────────────────────────
    //
    public static void runLLMStep(
        String agentDeveloperName,
        String inputContextJson,
        String triggerType,
        Id runId,
        List<LLMMessage> history
    ) {
        try {
            aao__Agent_Definition__mdt agentDef = [
                SELECT aao__Goal__c,
                       aao__SystemPrompt__c,
                       aao__LLMProvider__c,
                       aao__MaxSteps__c
                FROM aao__Agent_Definition__mdt
                WHERE DeveloperName = :agentDeveloperName
                LIMIT 1
            ];

            Integer currentStep = ExecutionLogger.getCurrentStep(runId);
            Integer maxSteps = agentDef.aao__MaxSteps__c != null
                ? Integer.valueOf(agentDef.aao__MaxSteps__c)
                : 10;

            if (currentStep >= maxSteps) {
                ExecutionLogger.finishRun(runId, null, 'Failed', 'Max steps exceeded');
                return;
            }

            Map<String, aao__Agent_Tool_Definition__mdt> toolDefs =
                ToolRegistry.getToolDefinitionsForAgent(agentDeveloperName);

            String toolManifest = buildToolManifest(toolDefs);

            String systemPrompt =
                agentDef.aao__SystemPrompt__c +
                '\n\nYou have access to the following tools. ' +
                'You may ONLY call tools from this list.\n\n' +
                toolManifest +
                '\n\nAfter receiving a tool output, decide whether to call another tool or return a final answer. ' +
                'You may ONLY respond with {"tool":..., "args":...} or {"final":{...}}.';

            if (history.isEmpty() || history[0].role != 'system') {
                history.add(0, new LLMMessage('system', systemPrompt));
            }

            LLMClient client = LLMClientFactory.forProvider(agentDef.aao__LLMProvider__c);
            LLMRequest req = new LLMRequest();
            req.messages = history;

            LLMResponse res = client.complete(req);

            ExecutionLogger.logStep(
                runId,
                new AgentStepLog(
                    ExecutionLogger.nextStepNumber(runId),
                    'LLMCall',
                    JSON.serialize(req),
                    res.rawResponse,
                    null,
                    null,
                    'Completed',
                    null
                )
            );

            Map<String, Object> parsed = (Map<String, Object>)JSON.deserializeUntyped(res.text);

            if (parsed.containsKey('final')) {
                Map<String, Object> finalResult = (Map<String, Object>)parsed.get('final');
                Boolean isError = finalResult.containsKey('error');

                ExecutionLogger.finishRun(
                    runId,
                    JSON.serialize(finalResult),
                    isError ? 'Failed' : 'Succeeded',
                    isError ? String.valueOf(finalResult.get('error')) : null
                );
                return;
            }

            if (parsed.containsKey('tool')) {
                String toolName = (String)parsed.get('tool');
                Map<String, Object> args = (Map<String, Object>)parsed.get('args');

                if (ExecutionLogger.hasIdenticalToolCall(runId, toolName, args)) {
                    // Instead of failing, instruct LLM to finalize
                    history.add(new LLMMessage(
                        'assistant',
                        '{"error":"Repeated tool call detected"}'
                    ));
                    history.add(new LLMMessage(
                        'user',
                        '{"instruction":"The previous tool call was identical. You must now return a final answer."}'
                    ));

                    scheduleNextLLMStep(runId, agentDeveloperName, triggerType, history);
                    return;
                }

                scheduleNextToolStep(runId, agentDeveloperName, triggerType, history, toolName, args);
                return;
            }

            ExecutionLogger.finishRun(runId, res.rawResponse, 'Failed', 'Invalid LLM response');

        } catch (Exception e) {
            String runAsUser = '[DIAGNOSTIC] Running as: ' + UserInfo.getName() + ' (' + UserInfo.getUserId() + ') | ';
            ExecutionLogger.finishRun(runId, null, 'Failed', runAsUser + e.getMessage());
        }
    }


    //
    // ───────────────────────────────────────────────────────────────
    // 3. TOOL STEP (NO CALLOUTS)
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
        try {
            Map<String, aao__Agent_Tool_Definition__mdt> toolDefs =
                ToolRegistry.getToolDefinitionsForAgent(agentDeveloperName);

            if (!toolDefs.containsKey(toolName)) {
                ExecutionLogger.finishRun(runId, null, 'Failed', 'Invalid tool: ' + toolName);
                return;
            }

            aao__Agent_Tool_Definition__mdt def = toolDefs.get(toolName);
            AgentTool tool = ToolRegistry.getToolByClassName(def.aao__Tool_Class__c);

            AgentToolResult toolResult = tool.run(args);

            ExecutionLogger.logStep(
                runId,
                new AgentStepLog(
                    ExecutionLogger.nextStepNumber(runId),
                    'ToolCall',
                    null,
                    null,
                    JSON.serialize(args),
                    JSON.serialize(toolResult),
                    toolResult.success ? 'Completed' : 'Failed',
                    toolName
                )
            );

            history.add(new LLMMessage(
                'assistant',
                JSON.serialize(new Map<String, Object>{
                    'tool'   => toolName,
                    'output' => toolResult
                }))
            );

            history.add(new LLMMessage(
                'user',
                '{"instruction":"Given the tool output above, decide whether to call another tool or return a final answer. Only respond with {\"tool\":..., \"args\":...} or {\"final\":{...}}."}'
            ));

            scheduleNextLLMStep(runId, agentDeveloperName, triggerType, history);

        } catch (Exception e) {
            String runAsUser = '[DIAGNOSTIC] Running as: ' + UserInfo.getName() + ' (' + UserInfo.getUserId() + ') | ';
            ExecutionLogger.finishRun(runId, null, 'Failed', runAsUser + e.getMessage());
        }
    }


    //
    // ───────────────────────────────────────────────────────────────
    // STEP SCHEDULING (PLATFORM EVENT HOP — RESETS QUEUEABLE CHAIN DEPTH)
    // ───────────────────────────────────────────────────────────────
    //
    private static void scheduleNextLLMStep(
        Id runId,
        String agentDeveloperName,
        String triggerType,
        List<LLMMessage> history
    ) {
        update new Agent_Run__c(Id = runId, History_Json__c = JSON.serialize(history));

        EventBus.publish(new Agent_Step_Event__e(
            Run_Id__c = runId,
            Agent_Developer_Name__c = agentDeveloperName,
            Trigger_Type__c = triggerType,
            Step_Type__c = 'LLM'
        ));
    }

    private static void scheduleNextToolStep(
        Id runId,
        String agentDeveloperName,
        String triggerType,
        List<LLMMessage> history,
        String toolName,
        Map<String, Object> args
    ) {
        update new Agent_Run__c(Id = runId, History_Json__c = JSON.serialize(history));

        EventBus.publish(new Agent_Step_Event__e(
            Run_Id__c = runId,
            Agent_Developer_Name__c = agentDeveloperName,
            Trigger_Type__c = triggerType,
            Step_Type__c = 'Tool',
            Tool_Name__c = toolName,
            Tool_Args_Json__c = JSON.serialize(args)
        ));
    }


    //
    // ───────────────────────────────────────────────────────────────
    // TOOL MANIFEST
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
