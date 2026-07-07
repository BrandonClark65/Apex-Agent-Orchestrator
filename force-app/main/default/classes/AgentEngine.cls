/**
 * @description Core state machine for the agent execution loop. `runAgent` is the only
 * public entry point (invoked from LWC/Flow via `@AuraEnabled`); every subsequent LLM call
 * or tool call happens asynchronously as its own transaction, chained together by publishing
 * an `Agent_Step_Event__e` platform event rather than calling `System.enqueueJob` directly.
 * `AgentStepEventTrigger` picks up that event and enqueues the next `AgentRunQueueable` or
 * `AgentToolQueueable` — this event hop resets the queueable chain depth counter so long
 * agent runs don't hit Salesforce's queueable nesting limit.
 *
 * The model's response is constrained to exactly one of `{"tool":...}`, `{"tools":[...]}`
 * (parallel tool calls), or `{"final":{...}}`; `runLLMStep` parses on that contract, so
 * changing the system prompt's response format requires updating the parser here too.
 *
 * Multi-agent collaboration: a tool may return `AgentToolResult.pending` (see `SubAgentTool`)
 * to start a child agent run instead of completing inline. The parent run then suspends —
 * its ToolCall step is logged as `'Pending'` and nothing further is scheduled — until the
 * child run's `ExecutionLogger.finishRun` calls `resumeParentRun` with the child's final
 * output as the tool result.
 * @group Agent Engine
 */
public with sharing class AgentEngine {
  // Consecutive failed steps (LLM or tool) allowed before a run is hard-failed.
  private static final Integer MAX_CONSECUTIVE_ERRORS = 3;

  //
  // ───────────────────────────────────────────────────────────────
  // 1. PUBLIC ENTRY POINT
  // ───────────────────────────────────────────────────────────────
  //
  /**
   * @description Starts a new agent run: creates the `Agent_Run__c` header record, seeds
   * conversation history with the user's input, and enqueues the first LLM step. Returns
   * immediately with the run Id — the run itself completes asynchronously.
   * @param agentDeveloperName DeveloperName of the `Agent_Definition__mdt` record to run.
   * @param inputContextJson JSON string passed to the LLM as the initial user message.
   * @param triggerType Free-text label describing what triggered this run (e.g. `'Flow'`, `'LWC'`), stored for observability.
   * @return Id of the newly created Agent_Run__c record.
   */
  @AuraEnabled
  public static Id runAgent(
    String agentDeveloperName,
    String inputContextJson,
    String triggerType
  ) {
    Id runId = ExecutionLogger.startRun(
      agentDeveloperName,
      inputContextJson,
      triggerType
    );

    List<LLMMessage> history = new List<LLMMessage>{
      new LLMMessage('user', inputContextJson)
    };

    System.enqueueJob(
      new AgentRunQueueable(
        agentDeveloperName,
        inputContextJson,
        triggerType,
        runId,
        history
      )
    );

    return runId;
  }

  /**
   * @description Starts the next turn of a multi-turn conversation: creates the session on
   * first send, seeds history from the previous turn (minus its system message, so the next
   * LLM step rebuilds a fresh system prompt against the current tool manifest), appends the
   * new user message, and enqueues the run exactly like `runAgent`. The session is locked
   * `Busy` while the turn is in flight — concurrent sends throw — and is released by
   * `ExecutionLogger.finishRun` via `SessionService.onRunFinished`.
   * @param agentDeveloperName DeveloperName of the `Agent_Definition__mdt` record to run.
   * @param userMessage The user's chat message for this turn.
   * @param sessionId Existing `Agent_Session__c` to continue, or null to start a new thread.
   * @return Id of the newly created Agent_Run__c record for this turn.
   */
  @AuraEnabled
  public static Id runAgentInSession(
    String agentDeveloperName,
    String userMessage,
    Id sessionId,
    String triggerType
  ) {
    if (String.isBlank(userMessage)) {
      throw new AuraHandledException('userMessage is required');
    }

    List<LLMMessage> history = new List<LLMMessage>();
    Integer turnNumber = 1;

    if (sessionId == null) {
      sessionId = SessionService.startSession(
        agentDeveloperName,
        userMessage
      );
      update new Agent_Session__c(Id = sessionId, Status__c = 'Busy');
    } else {
      // Lock the session so two simultaneous sends can't both pass the Busy check.
      Agent_Session__c session = [
        SELECT Status__c, Agent__c, Turn_Count__c
        FROM Agent_Session__c
        WHERE Id = :sessionId
        LIMIT 1
        FOR UPDATE
      ];
      if (session.Status__c == 'Busy') {
        throw new AuraHandledException(
          'This session already has a run in flight. Wait for it to finish before sending another message.'
        );
      }
      if (session.Status__c == 'Closed') {
        throw new AuraHandledException(
          'This session is closed. Start a new session to continue.'
        );
      }
      agentDeveloperName = session.Agent__c;
      turnNumber =
        (session.Turn_Count__c == null
          ? 0
          : Integer.valueOf(session.Turn_Count__c)) + 1;
      update new Agent_Session__c(Id = sessionId, Status__c = 'Busy');

      history = SessionService.loadSeedHistory(sessionId);
    }

    history.add(new LLMMessage('user', userMessage));

    Id runId = ExecutionLogger.startRun(
      agentDeveloperName,
      userMessage,
      String.isBlank(triggerType) ? 'UI' : triggerType
    );
    update new aao__Agent_Run__c(
      Id = runId,
      Session__c = sessionId,
      Turn_Number__c = turnNumber
    );

    System.enqueueJob(
      new AgentRunQueueable(
        agentDeveloperName,
        userMessage,
        triggerType,
        runId,
        history
      )
    );

    return runId;
  }

  //
  // ───────────────────────────────────────────────────────────────
  // 2. LLM STEP (CALLOUTS ALLOWED)
  // ───────────────────────────────────────────────────────────────
  //
  /**
   * @description Runs one LLM turn of an agent run: loads the `Agent_Definition__mdt`,
   * builds the system prompt and tool manifest from `ToolRegistry`, calls the configured
   * `LLMClient`, and parses the response against the tool/tools/final contract. Dispatches
   * to a tool step (single or parallel) or finishes the run, logging every outcome via
   * `ExecutionLogger`. Must run inside a `Database.AllowsCallouts` context (see `AgentRunQueueable`).
   * @param agentDeveloperName DeveloperName of the `Agent_Definition__mdt` record being run.
   * @param inputContextJson Original input context JSON the run was started with (unused after the first step; kept for signature symmetry with `runAgent`).
   * @param triggerType Free-text trigger label carried through for logging/event propagation.
   * @param runId Id of the `Agent_Run__c` this step belongs to.
   * @param history Conversation history so far; mutated in place as the step progresses.
   */
  public static void runLLMStep(
    String agentDeveloperName,
    String inputContextJson,
    String triggerType,
    Id runId,
    List<LLMMessage> history
  ) {
    try {
      aao__Agent_Definition__mdt agentDef = [
        SELECT
          aao__Goal__c,
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

      Map<String, aao__Agent_Tool_Definition__mdt> toolDefs = ToolRegistry.getToolDefinitionsForAgent(
        agentDeveloperName
      );

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

      LLMClient client = LLMClientFactory.forProvider(
        agentDef.aao__LLMProvider__c
      );
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
            ? (Map<String, Object>) rawParsed
            : new Map<String, Object>();
        } catch (Exception parseEx) {
          parseError = 'Response was malformed JSON: ' + parseEx.getMessage();
        }
      }
      Boolean isValidContract =
        parseError == null &&
        (parsed.containsKey('final') ||
        parsed.containsKey('tool') ||
        parsed.containsKey('tools'));

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
        Map<String, Object> finalResult = (Map<String, Object>) parsed.get(
          'final'
        );
        Boolean isError = finalResult.containsKey('error');

        // Persist the completed transcript (including the final assistant reply) —
        // History_Json__c is otherwise only written when a *next* step is scheduled,
        // and follow-up session turns seed from it.
        history.add(new LLMMessage('assistant', res.text));
        update new aao__Agent_Run__c(
          Id = runId,
          aao__History_Json__c = JSON.serialize(history)
        );

        ExecutionLogger.finishRun(
          runId,
          JSON.serialize(finalResult),
          isError ? 'Failed' : 'Succeeded',
          isError ? String.valueOf(finalResult.get('error')) : null
        );
        return;
      }

      if (parsed.containsKey('tools')) {
        List<Object> toolCalls = (List<Object>) parsed.get('tools');

        if (toolCalls == null || toolCalls.isEmpty()) {
          retryOrFail(
            runId,
            agentDeveloperName,
            triggerType,
            history,
            'Empty tools array in LLM response',
            'Empty tools array in LLM response'
          );
          return;
        }

        scheduleParallelToolSteps(
          runId,
          agentDeveloperName,
          triggerType,
          history,
          toolCalls
        );
        return;
      }

      if (parsed.containsKey('tool')) {
        String toolName = (String) parsed.get('tool');
        Map<String, Object> args = (Map<String, Object>) parsed.get('args');

        if (ExecutionLogger.hasIdenticalToolCall(runId, toolName, args)) {
          history.add(
            new LLMMessage(
              'assistant',
              '{"error":"Repeated tool call detected"}'
            )
          );
          history.add(
            new LLMMessage(
              'user',
              '{"instruction":"The previous tool call was identical. You must now return a final answer."}'
            )
          );

          scheduleNextLLMStep(runId, agentDeveloperName, triggerType, history);
          return;
        }

        scheduleNextToolStep(
          runId,
          agentDeveloperName,
          triggerType,
          history,
          toolName,
          args
        );
        return;
      }

      // Step already logged above (as 'Failed') — just evaluate whether to retry or hard-fail.
      // Distinguish malformed JSON from wrong contract key so the model gets actionable feedback.
      String logMsg;
      String llmMsg;
      if (parseError != null) {
        logMsg = parseError + ' | raw: ' + res.rawResponse;
        llmMsg =
          parseError +
          '. Ensure your response is valid, properly-closed JSON with exactly one top-level key: "tool", "tools", or "final".';
      } else {
        logMsg =
          'LLM response did not match contract (expected tool/tools/final key). Response text: ' +
          res.text.left(500) +
          ' | raw: ' +
          res.rawResponse;
        llmMsg = 'Response did not contain a "tool", "tools", or "final" key. Respond only with one of: {"tool":...}, {"tools":[...]}, or {"final":{...}}.';
      }
      retryOrFail(
        runId,
        agentDeveloperName,
        triggerType,
        history,
        logMsg,
        llmMsg
      );
    } catch (Exception e) {
      String runAsUser =
        '[DIAGNOSTIC] Running as: ' +
        UserInfo.getName() +
        ' (' +
        UserInfo.getUserId() +
        ') | ';
      handleStepError(
        runId,
        agentDeveloperName,
        triggerType,
        history,
        'LLMCall',
        null,
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
  /**
   * @description Runs one tool call: resolves the tool's Apex class via `ToolRegistry`,
   * executes it, and logs the result. Intentionally does not run in a
   * `Database.AllowsCallouts` context — tool classes may query/describe/DML Salesforce
   * data but must not make HTTP callouts. Detects whether this call is part of a parallel
   * batch (via `Agent_Run__c.PendingToolCount__c`) and routes to `completeParallelToolStep`
   * instead of directly scheduling the next LLM step when it is.
   * @param agentDeveloperName DeveloperName of the `Agent_Definition__mdt` record being run.
   * @param triggerType Free-text trigger label carried through for logging/event propagation.
   * @param runId Id of the `Agent_Run__c` this step belongs to.
   * @param history Conversation history so far; mutated in place for non-parallel calls.
   * @param toolName DeveloperName of the `Agent_Tool_Definition__mdt` to invoke.
   * @param args Tool arguments as parsed from the LLM's response JSON.
   */
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
      SELECT PendingToolCount__c, Depth__c
      FROM Agent_Run__c
      WHERE Id = :runId
      LIMIT 1
    ];
    Boolean isParallel =
      runCheck.PendingToolCount__c != null &&
      runCheck.PendingToolCount__c > 0;

    // Expose run-level context to tools (SubAgentTool reads this to link child runs
    // to this run and enforce the nesting-depth guard).
    AgentToolContext.runId = runId;
    AgentToolContext.agentDeveloperName = agentDeveloperName;
    AgentToolContext.triggerType = triggerType;
    AgentToolContext.depth = runCheck.Depth__c != null
      ? Integer.valueOf(runCheck.Depth__c)
      : 0;

    try {
      Map<String, aao__Agent_Tool_Definition__mdt> toolDefs = ToolRegistry.getToolDefinitionsForAgent(
        agentDeveloperName
      );

      if (!toolDefs.containsKey(toolName)) {
        if (isParallel) {
          completeParallelToolStep(
            runId,
            agentDeveloperName,
            triggerType,
            toolName,
            null,
            'Invalid tool: ' + toolName,
            JSON.serialize(args)
          );
        } else {
          handleStepError(
            runId,
            agentDeveloperName,
            triggerType,
            history,
            'ToolCall',
            toolName,
            'Invalid tool: ' + toolName,
            'Invalid tool: ' + toolName
          );
        }
        return;
      }

      aao__Agent_Tool_Definition__mdt def = toolDefs.get(toolName);
      AgentTool tool = ToolRegistry.getToolByClassName(def.aao__Tool_Class__c);

      AgentToolResult toolResult = tool.run(args);

      if (toolResult.pending == true) {
        // The tool started a sub-agent run instead of completing inline. Log this step
        // as 'Pending' and stop scheduling — the run resumes via resumeParentRun when
        // the child run finishes. In parallel mode PendingToolCount__c is intentionally
        // NOT decremented here; the child's completion decrements it.
        suspendForSubAgent(runId, toolName, toolResult, JSON.serialize(args));
        return;
      }

      if (isParallel) {
        // logStep happens inside the FOR UPDATE lock in completeParallelToolStep
        // to prevent concurrent Agent_Step__c inserts from causing lock conflicts
        // on the Agent_Run__c parent record.
        completeParallelToolStep(
          runId,
          agentDeveloperName,
          triggerType,
          toolName,
          toolResult,
          null,
          JSON.serialize(args)
        );
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
        history.add(
          new LLMMessage(
            'assistant',
            JSON.serialize(
              new Map<String, Object>{
                'tool' => toolName,
                'output' => toolResult
              }
            )
          )
        );

        history.add(
          new LLMMessage(
            'user',
            '{"instruction":"Given the tool output above, decide whether to call another tool or return a final answer. ' +
            'Only respond with {\\"tool\\":..., \\"args\\":...} or {\\"tools\\":[...]} or {\\"final\\":{...}}."}'
          )
        );

        scheduleNextLLMStep(runId, agentDeveloperName, triggerType, history);
      }
    } catch (Exception e) {
      String runAsUser =
        '[DIAGNOSTIC] Running as: ' +
        UserInfo.getName() +
        ' (' +
        UserInfo.getUserId() +
        ') | ';
      if (isParallel) {
        // logStep also handled inside the lock for error path
        completeParallelToolStep(
          runId,
          agentDeveloperName,
          triggerType,
          toolName,
          null,
          runAsUser + e.getMessage(),
          JSON.serialize(args)
        );
      } else {
        handleStepError(
          runId,
          agentDeveloperName,
          triggerType,
          history,
          'ToolCall',
          toolName,
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

    retryOrFail(
      runId,
      agentDeveloperName,
      triggerType,
      history,
      logMessage,
      llmMessage
    );
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
    if (
      ExecutionLogger.getConsecutiveErrorCount(runId) >= MAX_CONSECUTIVE_ERRORS
    ) {
      ExecutionLogger.finishRun(runId, null, 'Failed', logMessage);
      return;
    }

    history.add(
      new LLMMessage(
        'assistant',
        JSON.serialize(new Map<String, Object>{ 'error' => llmMessage })
      )
    );
    history.add(
      new LLMMessage(
        'user',
        '{"instruction":"The previous step failed. Adjust your approach and respond with ' +
        '{\\"tool\\":..., \\"args\\":...} or {\\"tools\\":[...]} or {\\"final\\":{...}}."}'
      )
    );

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
    update new Agent_Run__c(
      Id = runId,
      History_Json__c = JSON.serialize(history)
    );

    EventBus.publish(
      new Agent_Step_Event__e(
        Run_Id__c = runId,
        Agent_Developer_Name__c = agentDeveloperName,
        Trigger_Type__c = triggerType,
        Step_Type__c = 'LLM'
      )
    );
  }

  private static void scheduleNextToolStep(
    Id runId,
    String agentDeveloperName,
    String triggerType,
    List<LLMMessage> history,
    String toolName,
    Map<String, Object> args
  ) {
    update new Agent_Run__c(
      Id = runId,
      History_Json__c = JSON.serialize(history)
    );

    EventBus.publish(
      new Agent_Step_Event__e(
        Run_Id__c = runId,
        Agent_Developer_Name__c = agentDeveloperName,
        Trigger_Type__c = triggerType,
        Step_Type__c = 'Tool',
        Tool_Name__c = toolName,
        Tool_Args_Json__c = JSON.serialize(args)
      )
    );
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
      Map<String, Object> call = (Map<String, Object>) tc;
      String toolName = (String) call.get('tool');
      Map<String, Object> args = (Map<String, Object>) call.get('args');
      events.add(
        new Agent_Step_Event__e(
          Run_Id__c = runId,
          Agent_Developer_Name__c = agentDeveloperName,
          Trigger_Type__c = triggerType,
          Step_Type__c = 'Tool',
          Tool_Name__c = toolName,
          Tool_Args_Json__c = JSON.serialize(args)
        )
      );
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
        'ToolCall',
        null,
        null,
        argsJson,
        errorMessage != null ? errorMessage : JSON.serialize(result),
        errorMessage != null
          ? 'Failed'
          : (result.success ? 'Completed' : 'Failed'),
        toolName
      )
    );

    List<LLMMessage> merged = (List<LLMMessage>) JSON.deserialize(
      run.History_Json__c,
      List<LLMMessage>.class
    );

    if (errorMessage != null) {
      merged.add(
        new LLMMessage(
          'assistant',
          JSON.serialize(
            new Map<String, Object>{
              'tool' => toolName,
              'error' => errorMessage
            }
          )
        )
      );
    } else {
      merged.add(
        new LLMMessage(
          'assistant',
          JSON.serialize(
            new Map<String, Object>{ 'tool' => toolName, 'output' => result }
          )
        )
      );
    }

    Integer remaining = run.PendingToolCount__c != null
      ? Integer.valueOf(run.PendingToolCount__c) - 1
      : 0;

    if (remaining == 0) {
      merged.add(
        new LLMMessage(
          'user',
          '{"instruction":"Given the tool outputs above, decide whether to call more tools or return a final answer. ' +
          'Only respond with {\\"tool\\":..., \\"args\\":...} or {\\"tools\\":[...]} or {\\"final\\":{...}}."}'
        )
      );
    }

    update new Agent_Run__c(
      Id = runId,
      History_Json__c = JSON.serialize(merged),
      PendingToolCount__c = remaining
    );

    if (remaining == 0) {
      EventBus.publish(
        new Agent_Step_Event__e(
          Run_Id__c = runId,
          Agent_Developer_Name__c = agentDeveloperName,
          Trigger_Type__c = triggerType,
          Step_Type__c = 'LLM'
        )
      );
    }
  }

  //
  // ───────────────────────────────────────────────────────────────
  // SUB-AGENT LIFECYCLE (SUSPEND / RESUME)
  // ───────────────────────────────────────────────────────────────
  // A tool may return AgentToolResult.pending to indicate it started a child agent run
  // instead of completing inline (see SubAgentTool). The parent run then suspends: its
  // ToolCall step is logged with status 'Pending' and no next step is scheduled. When the
  // child run finishes, ExecutionLogger.finishRun calls resumeParentRun, which completes
  // the pending step with the child's final output and re-enters the parent's loop.
  //

  /**
   * @description Creates a child `Agent_Run__c` linked to a parent run, with seeded history,
   * ready to execute. Called by `SubAgentTool.run`. Deliberately does NOT publish the child's
   * first LLM step event — `suspendForSubAgent` does that after the parent's pending step and
   * `Parent_Step__c` linkage are in place, so the child can never finish before the parent
   * knows how to be resumed.
   * @param agentDeveloperName DeveloperName of the child `Agent_Definition__mdt` to run.
   * @param inputContextJson Task for the child agent, passed as its initial user message.
   * @param parentRunId Id of the `Agent_Run__c` that is delegating.
   * @param depth Nesting depth of the child run (parent depth + 1).
   * @return Id of the newly created child Agent_Run__c record.
   */
  public static Id startSubAgentRun(
    String agentDeveloperName,
    String inputContextJson,
    Id parentRunId,
    Integer depth
  ) {
    Id childRunId = ExecutionLogger.startRun(
      agentDeveloperName,
      inputContextJson,
      'SubAgent'
    );

    List<LLMMessage> history = new List<LLMMessage>{
      new LLMMessage('user', inputContextJson)
    };

    update new Agent_Run__c(
      Id = childRunId,
      Parent_Run__c = parentRunId,
      Depth__c = depth,
      History_Json__c = JSON.serialize(history)
    );

    return childRunId;
  }

  // Suspends the run after a tool returned a pending result: logs the ToolCall step as
  // 'Pending', links the child run back to that step, and only then starts the child's
  // first LLM step. The FOR UPDATE lock serializes the step insert with sibling parallel
  // jobs, same as completeParallelToolStep. PendingToolCount__c is left untouched — for a
  // parallel batch the child's completion performs this tool's decrement in resumeParentRun.
  private static void suspendForSubAgent(
    Id runId,
    String toolName,
    AgentToolResult result,
    String argsJson
  ) {
    Id childRunId = result.data != null &&
      result.data.get('childRunId') != null
      ? Id.valueOf(String.valueOf(result.data.get('childRunId')))
      : null;
    if (childRunId == null) {
      throw new AgentException(
        'Pending result from tool ' +
          toolName +
          ' is missing data.childRunId; cannot suspend the run.'
      );
    }

    Agent_Run__c run = [
      SELECT Id
      FROM Agent_Run__c
      WHERE Id = :runId
      FOR UPDATE
    ];

    Id stepId = ExecutionLogger.logStep(
      runId,
      new AgentStepLog(
        ExecutionLogger.nextStepNumber(runId),
        'ToolCall',
        null,
        null,
        argsJson,
        JSON.serialize(result),
        'Pending',
        toolName
      )
    );

    Agent_Run__c child = [
      SELECT Agent__c
      FROM Agent_Run__c
      WHERE Id = :childRunId
      LIMIT 1
    ];
    update new Agent_Run__c(Id = childRunId, Parent_Step__c = stepId);

    EventBus.publish(
      new Agent_Step_Event__e(
        Run_Id__c = childRunId,
        Agent_Developer_Name__c = child.Agent__c,
        Trigger_Type__c = 'SubAgent',
        Step_Type__c = 'LLM'
      )
    );
  }

  /**
   * @description Resumes a suspended parent run after one of its child (sub-agent) runs
   * finishes. Called by `ExecutionLogger.finishRun` for any finishing run that has a
   * `Parent_Run__c` — including hard-failure paths, so a failed child surfaces to the parent
   * as a failed tool result rather than leaving the parent hanging. Completes the parent's
   * pending ToolCall step with the child's final output, merges that output into the parent's
   * history, and re-enters the parent's LLM loop (or, when the parent is mid parallel batch,
   * performs this tool's counter decrement and only re-enters when the batch is drained).
   * No-ops if the parent is no longer `Running`.
   * @param parentRunId Id of the suspended parent `Agent_Run__c`.
   * @param parentStepId Id of the parent's `'Pending'` ToolCall step (`Agent_Run__c.Parent_Step__c` on the child), may be null if suspension never completed.
   * @param childRunId Id of the child run that just finished.
   * @param childAgentName DeveloperName of the child's agent definition.
   * @param childFinalOutput Child run's serialized final output, or null.
   * @param childStatus Child run's terminal status (`'Succeeded'` or `'Failed'`).
   * @param childErrorMessage Child run's error message when failed, otherwise null.
   */
  public static void resumeParentRun(
    Id parentRunId,
    Id parentStepId,
    Id childRunId,
    String childAgentName,
    String childFinalOutput,
    String childStatus,
    String childErrorMessage
  ) {
    List<Agent_Run__c> parents = [
      SELECT
        Status__c,
        PendingToolCount__c,
        History_Json__c,
        Agent__c,
        Trigger_Type__c
      FROM Agent_Run__c
      WHERE Id = :parentRunId
      FOR UPDATE
    ];
    if (parents.isEmpty() || parents[0].Status__c != 'Running') {
      return;
    }
    Agent_Run__c parent = parents[0];

    Boolean childSucceeded = childStatus == 'Succeeded';
    Map<String, Object> data = new Map<String, Object>{
      'agentName' => childAgentName,
      'childRunId' => childRunId
    };
    if (childFinalOutput != null) {
      try {
        data.put('output', JSON.deserializeUntyped(childFinalOutput));
      } catch (Exception parseEx) {
        data.put('output', childFinalOutput);
      }
    }
    AgentToolResult result = new AgentToolResult(
      childSucceeded,
      childSucceeded
        ? 'Sub-agent ' + childAgentName + ' completed'
        : 'Sub-agent ' + childAgentName + ' failed: ' + childErrorMessage,
      data
    );

    String toolName = 'SubAgentTool';
    if (parentStepId != null) {
      List<Agent_Step__c> steps = [
        SELECT Tool__c
        FROM Agent_Step__c
        WHERE Id = :parentStepId
        LIMIT 1
      ];
      if (!steps.isEmpty()) {
        if (steps[0].Tool__c != null) {
          toolName = steps[0].Tool__c;
        }
        update new Agent_Step__c(
          Id = parentStepId,
          Tool_Output__c = JSON.serialize(result),
          Status__c = childSucceeded ? 'Completed' : 'Failed'
        );
      }
    }

    List<LLMMessage> merged = (List<LLMMessage>) JSON.deserialize(
      parent.History_Json__c,
      List<LLMMessage>.class
    );
    merged.add(
      new LLMMessage(
        'assistant',
        JSON.serialize(
          new Map<String, Object>{ 'tool' => toolName, 'output' => result }
        )
      )
    );

    // If the parent is mid parallel batch, this resume is the suspended tool's
    // deferred decrement; only re-enter the LLM loop once the batch is drained.
    Boolean isParallel =
      parent.PendingToolCount__c != null &&
      parent.PendingToolCount__c > 0;
    Integer remaining = isParallel
      ? Integer.valueOf(parent.PendingToolCount__c) - 1
      : 0;

    if (remaining == 0) {
      merged.add(
        new LLMMessage(
          'user',
          '{"instruction":"Given the tool output(s) above, decide whether to call more tools or return a final answer. ' +
          'Only respond with {\\"tool\\":..., \\"args\\":...} or {\\"tools\\":[...]} or {\\"final\\":{...}}."}'
        )
      );
    }

    update new Agent_Run__c(
      Id = parentRunId,
      History_Json__c = JSON.serialize(merged),
      PendingToolCount__c = remaining
    );

    if (remaining == 0) {
      EventBus.publish(
        new Agent_Step_Event__e(
          Run_Id__c = parentRunId,
          Agent_Developer_Name__c = parent.Agent__c,
          Trigger_Type__c = parent.Trigger_Type__c,
          Step_Type__c = 'LLM'
        )
      );
    }
  }

  //
  // ───────────────────────────────────────────────────────────────
  // TOOL MANIFEST
  // ───────────────────────────────────────────────────────────────
  //
  private static String buildToolManifest(
    Map<String, aao__Agent_Tool_Definition__mdt> toolDefs
  ) {
    List<String> entries = new List<String>();
    for (aao__Agent_Tool_Definition__mdt def : toolDefs.values()) {
      String entry =
        '  {\n' +
        '    "name": ' +
        JSON.serialize(def.DeveloperName) +
        ',\n' +
        '    "description": ' +
        JSON.serialize(def.aao__Description__c) +
        ',\n';

      if (String.isNotBlank(def.aao__PromptGuidance__c)) {
        entry +=
          '    "usage_guidance": ' +
          JSON.serialize(def.aao__PromptGuidance__c) +
          ',\n';
      }

      entry +=
        '    "input_schema": ' +
        def.aao__InputSchema__c +
        ',\n' +
        '    "output_schema": ' +
        def.aao__OutputSchema__c +
        '\n' +
        '  }';
      entries.add(entry);
    }
    return '[\n' + String.join(entries, ',\n') + '\n]';
  }
}
