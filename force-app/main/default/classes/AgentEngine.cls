public with sharing class AgentEngine {

    // Consecutive failed steps (LLM or tool) allowed before a run is hard-failed.
    private static final Integer MAX_CONSECUTIVE_ERRORS = 3;

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
                '\n\nAfter receiving tool output(s), decide whether to call more tools or return a final answer. ' +
                'You may ONLY respond with one of:\n' +
                '- {"tool":"<name>","args":{...}} — call a single tool\n' +
                '- {"tools":[{"tool":"<name>","args":{...}}, ...]} — call multiple independent tools in parallel\n' +
                '- {"final":{...}} — return the final answer';

            if (history.isEmpty() || history[0].role != 'system') {
                history.add(0, new LLMMessage('system', systemPrompt));
            }

            LLMClient client = LLMClientFactory.forProvider(agentDef.aao__LLMProvider__c);
            LLMRequest req = new LLMRequest();
            req.messages = history;

            LLMResponse res = client.complete(req);

            Map<String, Object> parsed = new Map<String, Object>();
            String parseError = null;

            if (String.isBlank(res.text)) {
                parseError = 'LLM returned empty content';
            } else {
                try {
                    Object rawParsed = JSON.deserializeUntyped(res.text);
                    parsed = rawParsed instanceof Map<String, Object>
                        ? (Map<String, Object>)rawParsed
                        : new Map<String, Object>();
                } catch (Exception parseEx) {
                    parseError = 'Response was malformed JSON: ' + parseEx.getMessage();
                }
            }
            Boolean isValidContract = parseError == null
                && (parsed.containsKey('final')
                    || parsed.containsKey('tool')
                    || parsed.containsKey('tools'));

            ExecutionLogger.logStep(
                runId,
                new AgentStepLog(
                    ExecutionLogger.nextStepNumber(runId),
                    'LLMCall',
                    JSON.serialize(req),
                    res.rawResponse,
                    null,
                    null,
                    isValidContract ? 'Completed' : 'Failed',
                    null
                )
            );

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

            if (parsed.containsKey('tools')) {
                List<Object> toolCalls = (List<Object>)parsed.get('tools');

                if (toolCalls == null || toolCalls.isEmpty()) {
                    retryOrFail(
                        runId, agentDeveloperName, triggerType, history,
                        'Empty tools array in LLM response',
                        'Empty tools array in LLM response'
                    );
                    return;
                }

                scheduleParallelToolSteps(runId, agentDeveloperName, triggerType, history, toolCalls);
                return;
            }

            if (parsed.containsKey('tool')) {
                String toolName = (String)parsed.get('tool');
                Map<String, Object> args = (Map<String, Object>)parsed.get('args');

                if (ExecutionLogger.hasIdenticalToolCall(runId, toolName, args)) {
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

            // Step already logged above (as 'Failed') — just evaluate whether to retry or hard-fail.
            // Distinguish malformed JSON from wrong contract key so the model gets actionable feedback.
            String logMsg;
            String llmMsg;
            if (parseError != null) {
                logMsg = parseError + ' | raw: ' + res.rawResponse;
                llmMsg = parseError + '. Ensure your response is valid, properly-closed JSON with exactly one top-level key: "tool", "tools", or "final".';
            } else {
                logMsg = 'LLM response did not match contract (expected tool/tools/final key). Response text: ' + res.text.left(500) + ' | raw: ' + res.rawResponse;
                llmMsg = 'Response did not contain a "tool", "tools", or "final" key. Respond only with one of: {"tool":...}, {"tools":[...]}, or {"final":{...}}.';
            }
            retryOrFail(runId, agentDeveloperName, triggerType, history, logMsg, llmMsg);

        } catch (Exception e) {
            String runAsUser = '[DIAGNOSTIC] Running as: ' + UserInfo.getName() + ' (' + UserInfo.getUserId() + ') | ';
            handleStepError(
                runId, agentDeveloperName, triggerType, history,
                'LLMCall', null,
                runAsUser + e.getMessage(),
                e.getMessage()
            );
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
        // Non-locking read to detect parallel mode before tool execution.
        // The actual atomic decrement happens later under FOR UPDATE.
        Agent_Run__c runCheck = [
            SELECT PendingToolCount__c
            FROM Agent_Run__c
            WHERE Id = :runId
            LIMIT 1
        ];
        Boolean isParallel = runCheck.PendingToolCount__c != null && runCheck.PendingToolCount__c > 0;

        try {
            Map<String, aao__Agent_Tool_Definition__mdt> toolDefs =
                ToolRegistry.getToolDefinitionsForAgent(agentDeveloperName);

            if (!toolDefs.containsKey(toolName)) {
                if (isParallel) {
                    completeParallelToolStep(runId, agentDeveloperName, triggerType, toolName, null, 'Invalid tool: ' + toolName, JSON.serialize(args));
                } else {
                    handleStepError(
                        runId, agentDeveloperName, triggerType, history,
                        'ToolCall', toolName,
                        'Invalid tool: ' + toolName,
                        'Invalid tool: ' + toolName
                    );
                }
                return;
            }

            aao__Agent_Tool_Definition__mdt def = toolDefs.get(toolName);
            AgentTool tool = ToolRegistry.getToolByClassName(def.aao__Tool_Class__c);

            AgentToolResult toolResult = tool.run(args);

            if (isParallel) {
                // logStep happens inside the FOR UPDATE lock in completeParallelToolStep
                // to prevent concurrent Agent_Step__c inserts from causing lock conflicts
                // on the Agent_Run__c parent record.
                completeParallelToolStep(runId, agentDeveloperName, triggerType, toolName, toolResult, null, JSON.serialize(args));
            } else {
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
                    '{"instruction":"Given the tool output above, decide whether to call another tool or return a final answer. ' +
                    'Only respond with {\\"tool\\":..., \\"args\\":...} or {\\"tools\\":[...]} or {\\"final\\":{...}}."}'
                ));

                scheduleNextLLMStep(runId, agentDeveloperName, triggerType, history);
            }

        } catch (Exception e) {
            String runAsUser = '[DIAGNOSTIC] Running as: ' + UserInfo.getName() + ' (' + UserInfo.getUserId() + ') | ';
            if (isParallel) {
                // logStep also handled inside the lock for error path
                completeParallelToolStep(runId, agentDeveloperName, triggerType, toolName, null, runAsUser + e.getMessage(), JSON.serialize(args));
            } else {
                handleStepError(
                    runId, agentDeveloperName, triggerType, history,
                    'ToolCall', toolName,
                    runAsUser + e.getMessage(),
                    e.getMessage()
                );
            }
        }
    }


    //
    // ───────────────────────────────────────────────────────────────
    // ERROR HANDLING / RETRY
    // ───────────────────────────────────────────────────────────────
    // Logs the failed step. If the run has failed MAX_CONSECUTIVE_ERRORS times
    // in a row, it's hard-failed; otherwise the error is handed back to the
    // LLM (as conversation context, not the diagnostic-laden log message) so
    // it can adjust course on the next step.
    //
    private static void handleStepError(
        Id runId,
        String agentDeveloperName,
        String triggerType,
        List<LLMMessage> history,
        String stepType,
        String toolName,
        String logMessage,
        String llmMessage
    ) {
        ExecutionLogger.logStep(
            runId,
            new AgentStepLog(
                ExecutionLogger.nextStepNumber(runId),
                stepType,
                null,
                stepType == 'LLMCall' ? logMessage : null,
                null,
                stepType == 'ToolCall' ? logMessage : null,
                'Failed',
                toolName
            )
        );

        retryOrFail(runId, agentDeveloperName, triggerType, history, logMessage, llmMessage);
    }

    // Assumes the failed step has already been logged by the caller.
    private static void retryOrFail(
        Id runId,
        String agentDeveloperName,
        String triggerType,
        List<LLMMessage> history,
        String logMessage,
        String llmMessage
    ) {
        if (ExecutionLogger.getConsecutiveErrorCount(runId) >= MAX_CONSECUTIVE_ERRORS) {
            ExecutionLogger.finishRun(runId, null, 'Failed', logMessage);
            return;
        }

        history.add(new LLMMessage(
            'assistant',
            JSON.serialize(new Map<String, Object>{ 'error' => llmMessage })
        ));
        history.add(new LLMMessage(
            'user',
            '{"instruction":"The previous step failed. Adjust your approach and respond with ' +
            '{\\"tool\\":..., \\"args\\":...} or {\\"tools\\":[...]} or {\\"final\\":{...}}."}'
        ));

        scheduleNextLLMStep(runId, agentDeveloperName, triggerType, history);
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

    // Sets PendingToolCount__c = N, saves history, then publishes one Tool event per call.
    private static void scheduleParallelToolSteps(
        Id runId,
        String agentDeveloperName,
        String triggerType,
        List<LLMMessage> history,
        List<Object> toolCalls
    ) {
        update new Agent_Run__c(
            Id = runId,
            History_Json__c = JSON.serialize(history),
            PendingToolCount__c = toolCalls.size()
        );

        List<Agent_Step_Event__e> events = new List<Agent_Step_Event__e>();
        for (Object tc : toolCalls) {
            Map<String, Object> call = (Map<String, Object>)tc;
            String toolName = (String)call.get('tool');
            Map<String, Object> args = (Map<String, Object>)call.get('args');
            events.add(new Agent_Step_Event__e(
                Run_Id__c = runId,
                Agent_Developer_Name__c = agentDeveloperName,
                Trigger_Type__c = triggerType,
                Step_Type__c = 'Tool',
                Tool_Name__c = toolName,
                Tool_Args_Json__c = JSON.serialize(args)
            ));
        }
        EventBus.publish(events);
    }

    // Called by each tool in a parallel batch. Acquires a FOR UPDATE lock on Agent_Run__c,
    // logs the step, merges this tool's result into the shared history, decrements the counter,
    // and — if this is the last tool to finish — publishes the next LLM step event.
    // logStep is intentionally inside the lock so Agent_Step__c child inserts from concurrent
    // parallel jobs don't conflict with each other's FOR UPDATE on the parent Agent_Run__c.
    private static void completeParallelToolStep(
        Id runId,
        String agentDeveloperName,
        String triggerType,
        String toolName,
        AgentToolResult result,
        String errorMessage,
        String argsJson
    ) {
        Agent_Run__c run = [
            SELECT PendingToolCount__c, History_Json__c
            FROM Agent_Run__c
            WHERE Id = :runId
            FOR UPDATE
        ];

        // Log the step inside the lock so each parallel job's Agent_Step__c insert is serialized.
        ExecutionLogger.logStep(
            runId,
            new AgentStepLog(
                ExecutionLogger.nextStepNumber(runId),
                'ToolCall', null, null,
                argsJson,
                errorMessage != null ? errorMessage : JSON.serialize(result),
                errorMessage != null ? 'Failed' : (result.success ? 'Completed' : 'Failed'),
                toolName
            )
        );

        List<LLMMessage> merged = (List<LLMMessage>)JSON.deserialize(
            run.History_Json__c, List<LLMMessage>.class
        );

        if (errorMessage != null) {
            merged.add(new LLMMessage(
                'assistant',
                JSON.serialize(new Map<String, Object>{ 'tool' => toolName, 'error' => errorMessage })
            ));
        } else {
            merged.add(new LLMMessage(
                'assistant',
                JSON.serialize(new Map<String, Object>{ 'tool' => toolName, 'output' => result })
            ));
        }

        Integer remaining = run.PendingToolCount__c != null
            ? Integer.valueOf(run.PendingToolCount__c) - 1
            : 0;

        if (remaining == 0) {
            merged.add(new LLMMessage(
                'user',
                '{"instruction":"Given the tool outputs above, decide whether to call more tools or return a final answer. ' +
                'Only respond with {\\"tool\\":..., \\"args\\":...} or {\\"tools\\":[...]} or {\\"final\\":{...}}."}'
            ));
        }

        update new Agent_Run__c(
            Id = runId,
            History_Json__c = JSON.serialize(merged),
            PendingToolCount__c = remaining
        );

        if (remaining == 0) {
            EventBus.publish(new Agent_Step_Event__e(
                Run_Id__c = runId,
                Agent_Developer_Name__c = agentDeveloperName,
                Trigger_Type__c = triggerType,
                Step_Type__c = 'LLM'
            ));
        }
    }


    //
    // ───────────────────────────────────────────────────────────────
    // TOOL MANIFEST
    // ───────────────────────────────────────────────────────────────
    //
    private static String buildToolManifest(Map<String, aao__Agent_Tool_Definition__mdt> toolDefs) {
        List<String> entries = new List<String>();
        for (aao__Agent_Tool_Definition__mdt def : toolDefs.values()) {
            String entry = '  {\n' +
                '    "name": ' + JSON.serialize(def.DeveloperName) + ',\n' +
                '    "description": ' + JSON.serialize(def.aao__Description__c) + ',\n';

            if (String.isNotBlank(def.aao__PromptGuidance__c)) {
                entry += '    "usage_guidance": ' + JSON.serialize(def.aao__PromptGuidance__c) + ',\n';
            }

            entry +=
                '    "input_schema": ' + def.aao__InputSchema__c + ',\n' +
                '    "output_schema": ' + def.aao__OutputSchema__c + '\n' +
                '  }';
            entries.add(entry);
        }
        return '[\n' + String.join(entries, ',\n') + '\n]';
    }
}
