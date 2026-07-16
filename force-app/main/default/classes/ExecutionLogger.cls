/**
 * @description Owns all persistence for the agent execution loop's observability data model:
 * one `Agent_Run__c` header row per `AgentEngine.runAgent` call, with child `Agent_Step__c`
 * rows (one per LLM call or tool call) written by `logStep`. Also provides the loop-termination
 * checks `AgentEngine` relies on — duplicate consecutive tool call detection (`hasIdenticalToolCall`)
 * and consecutive failure counting (`getConsecutiveErrorCount`).
 * @group Agent Engine
 */
public with sharing class ExecutionLogger {
  //
  // ───────────────────────────────────────────────────────────────
  // START RUN
  // ───────────────────────────────────────────────────────────────
  //
  /**
   * @description Creates the `Agent_Run__c` header record for a new run with status `'Running'`.
   * @param agentName DeveloperName of the `Agent_Definition__mdt` record being run.
   * @param inputContextJson JSON string the run was started with, stored for auditing.
   * @param triggerType Free-text trigger label; defaults to `'Unknown'` when blank.
   * @return Id of the newly created Agent_Run__c record.
   */
  public static Id startRun(
    String agentName,
    String inputContextJson,
    String triggerType
  ) {
    aao__Agent_Run__c run = new aao__Agent_Run__c(
      aao__Agent__c = agentName,
      aao__Status__c = 'Running',
      aao__Input_Context__c = inputContextJson,
      aao__Started_At__c = System.now(),
      aao__Trigger_Type__c = String.isBlank(triggerType)
        ? 'Unknown'
        : triggerType
    );
    insert run;
    return run.Id;
  }
  //
  // ───────────────────────────────────────────────────────────────
  // STEP NUMBER HELPERS
  // ───────────────────────────────────────────────────────────────
  //

  /**
   * @description Returns the step number to use for the next `Agent_Step__c` row on this run.
   * @param runId Id of the `Agent_Run__c` to count steps for.
   * @return Current step count + 1.
   */
  public static Integer nextStepNumber(Id runId) {
    Integer countSteps = [
      SELECT COUNT()
      FROM aao__Agent_Step__c
      WHERE aao__Agent_Run__c = :runId
    ];
    return countSteps + 1;
  }

  /**
   * @description Returns how many steps have been logged for this run so far, used by
   * `AgentEngine.runLLMStep` to enforce `Agent_Definition__mdt.MaxSteps__c`.
   * @param runId Id of the `Agent_Run__c` to count steps for.
   * @return Number of Agent_Step__c rows logged for this run.
   */
  public static Integer getCurrentStep(Id runId) {
    return [
      SELECT COUNT()
      FROM aao__Agent_Step__c
      WHERE aao__Agent_Run__c = :runId
    ];
  }
  //
  // ───────────────────────────────────────────────────────────────
  // Check for identical tool call (to avoid duplicates)
  // ───────────────────────────────────────────────────────────────
  //
  /**
   * @description Checks whether the most recently logged step on this run was a tool call
   * to `toolName` with arguments identical to `args` (compared via canonical JSON, not
   * reference equality). Used by `AgentEngine` to break infinite loops where the model
   * repeats the same tool call instead of finalizing.
   * @param runId Id of the `Agent_Run__c` to inspect.
   * @param toolName Tool name the LLM wants to call next.
   * @param args Tool arguments the LLM wants to call next, as parsed from its response JSON.
   * @return True if the last step was a ToolCall to the same tool with equivalent args.
   */
  public static Boolean hasIdenticalToolCall(
    Id runId,
    String toolName,
    Map<String, Object> args
  ) {
    // Compare against the most recent *ToolCall* step, not merely the most recent
    // step. `AgentEngine.runLLMStep` always logs the current LLMCall step before it
    // calls this guard, so an unfiltered "last step" query would always see that
    // LLMCall and the guard could never fire (it would bail on the step-type check).
    List<aao__Agent_Step__c> steps = [
      SELECT aao__Tool_Input__c, aao__Tool__c
      FROM aao__Agent_Step__c
      WHERE aao__Agent_Run__c = :runId AND aao__Step_Type__c = 'ToolCall'
      ORDER BY aao__Step_Number__c DESC
      LIMIT 1
    ];

    if (steps.isEmpty())
      return false;

    aao__Agent_Step__c last = steps[0];

    if (last.aao__Tool__c != toolName)
      return false;
    if (String.isBlank(last.aao__Tool_Input__c))
      return false;

    // Normalize both sides to canonical JSON before comparing.
    String lastNormalized = normalizeStoredInput(last.aao__Tool_Input__c);
    String currentNormalized = normalize(args);

    return lastNormalized == currentNormalized;
  }

  /**
   * @description Canonicalizes a stored `Tool_Input__c` value for comparison. The tool-step
   * logging path serializes the args map and then `AgentStepLog` serializes again, so the
   * stored value is usually double-encoded (a JSON string whose text is the args JSON). The
   * first parse then yields a `String`, not a `Map`; when that happens we parse once more so
   * the result lines up with `normalize(args)`. Single-encoded values are handled too.
   */
  private static String normalizeStoredInput(String storedInput) {
    Object parsed = JSON.deserializeUntyped(storedInput);
    if (parsed instanceof String) {
      parsed = JSON.deserializeUntyped((String) parsed);
    }
    return normalize(parsed);
  }

  /**
   * @description Produces a canonical JSON string with map keys recursively sorted, so two
   * argument structures that differ only in key order compare equal. Sorting is required
   * because Apex `JSON.deserializeUntyped` does not preserve a stable key order across
   * round-trips: the stored (double-encoded) side is parsed one more time than the live
   * args, which alone reorders keys and would defeat a plain serialize-based comparison.
   */
  private static String normalize(Object value) {
    return canonicalJson(value);
  }

  private static String canonicalJson(Object value) {
    if (value == null) {
      return 'null';
    }
    if (value instanceof Map<String, Object>) {
      Map<String, Object> m = (Map<String, Object>) value;
      List<String> keys = new List<String>(m.keySet());
      keys.sort();
      List<String> parts = new List<String>();
      for (String k : keys) {
        parts.add(JSON.serialize(k) + ':' + canonicalJson(m.get(k)));
      }
      return '{' + String.join(parts, ',') + '}';
    }
    if (value instanceof List<Object>) {
      List<String> parts = new List<String>();
      for (Object item : (List<Object>) value) {
        parts.add(canonicalJson(item));
      }
      return '[' + String.join(parts, ',') + ']';
    }
    // Primitives — let JSON.serialize handle escaping and numeric formatting.
    return JSON.serialize(value);
  }
  //
  // ───────────────────────────────────────────────────────────────
  // Count how many steps in a row (most recent first) have failed
  // ───────────────────────────────────────────────────────────────
  //
  /**
   * @description Counts how many of the most recent steps (up to 10, most recent first)
   * have `Status__c == 'Failed'`, stopping at the first non-failed step. Used by
   * `AgentEngine.retryOrFail` to hard-fail a run after `MAX_CONSECUTIVE_ERRORS` in a row.
   * @param runId Id of the `Agent_Run__c` to inspect.
   * @return Number of consecutive failed steps, most-recent-first.
   */
  public static Integer getConsecutiveErrorCount(Id runId) {
    List<aao__Agent_Step__c> steps = [
      SELECT aao__Status__c
      FROM aao__Agent_Step__c
      WHERE aao__Agent_Run__c = :runId
      ORDER BY aao__Step_Number__c DESC
      LIMIT 10
    ];

    Integer count = 0;
    for (aao__Agent_Step__c step : steps) {
      if (step.aao__Status__c != 'Failed')
        break;
      count++;
    }
    return count;
  }

  //
  // ───────────────────────────────────────────────────────────────
  // LOG STEP
  // ───────────────────────────────────────────────────────────────
  //
  /**
   * @description Inserts one `Agent_Step__c` child record for the given run, capturing an
   * LLM call or a tool call. Build the `log` argument with `new AgentStepLog(...)`.
   * @param runId Id of the parent `Agent_Run__c`.
   * @param log Step data to persist.
   * @return Id of the inserted Agent_Step__c record.
   */
  public static Id logStep(Id runId, AgentStepLog log) {
    aao__Agent_Step__c step = new aao__Agent_Step__c(
      aao__Agent_Run__c = runId,
      aao__Step_Number__c = log.stepNumber,
      aao__Step_Type__c = log.stepType,
      aao__LLM_Request__c = log.llmRequest,
      aao__LLM_Response__c = log.llmResponse,
      aao__Tool_Input__c = log.toolInput,
      aao__Tool_Output__c = log.toolOutput,
      aao__Status__c = log.status,
      aao__Tool__c = log.toolName,
      aao__Prompt_Tokens__c = log.promptTokens,
      aao__Completion_Tokens__c = log.completionTokens,
      aao__Total_Tokens__c = log.totalTokens
    );
    insert step;

    // Roll the step's token usage up onto the run. Only LLM-backed steps carry tokens;
    // tool steps leave all three null and skip the extra query/DML entirely.
    if (
      log.promptTokens != null ||
      log.completionTokens != null ||
      log.totalTokens != null
    ) {
      addRunTokenUsage(
        runId,
        log.promptTokens,
        log.completionTokens,
        log.totalTokens
      );
    }

    UIEventPublisher.publishStepCompleted(
      runId,
      getSessionId(runId),
      log.stepType,
      log.toolName,
      log.status
    );

    return step.Id;
  }

  /**
   * @description Adds one LLM step's token usage to the running totals on its parent run.
   * Each run aggregates only its own direct LLM/Summary steps — a sub-agent's tokens live on
   * the sub-agent's own run, not the parent's. Null contributions count as zero, so a
   * provider that reports only some of the three counts still accumulates the rest.
   * @param runId Id of the parent Agent_Run__c.
   * @param promptTokens Prompt tokens for this step, or null.
   * @param completionTokens Completion tokens for this step, or null.
   * @param totalTokens Total tokens for this step, or null.
   */
  private static void addRunTokenUsage(
    Id runId,
    Integer promptTokens,
    Integer completionTokens,
    Integer totalTokens
  ) {
    List<aao__Agent_Run__c> runs = [
      SELECT
        aao__Prompt_Tokens__c,
        aao__Completion_Tokens__c,
        aao__Total_Tokens__c
      FROM aao__Agent_Run__c
      WHERE Id = :runId
      LIMIT 1
    ];
    if (runs.isEmpty()) {
      return;
    }
    aao__Agent_Run__c run = runs[0];
    run.aao__Prompt_Tokens__c =
      zeroIfNull(run.aao__Prompt_Tokens__c) + zeroIfNull(promptTokens);
    run.aao__Completion_Tokens__c =
      zeroIfNull(run.aao__Completion_Tokens__c) + zeroIfNull(completionTokens);
    run.aao__Total_Tokens__c =
      zeroIfNull(run.aao__Total_Tokens__c) + zeroIfNull(totalTokens);
    update run;
  }

  private static Decimal zeroIfNull(Decimal value) {
    return value == null ? 0 : value;
  }

  private static Integer zeroIfNull(Integer value) {
    return value == null ? 0 : value;
  }

  /**
   * @description Returns the run's session Id, or null for one-shot / sub-agent runs.
   * @param runId Id of the Agent_Run__c to look up.
   * @return Session__c value or null.
   */
  private static Id getSessionId(Id runId) {
    List<aao__Agent_Run__c> runs = [
      SELECT Session__c
      FROM aao__Agent_Run__c
      WHERE Id = :runId
      LIMIT 1
    ];
    return runs.isEmpty() ? null : runs[0].Session__c;
  }
  //
  // ───────────────────────────────────────────────────────────────
  // FINISH RUN
  // ───────────────────────────────────────────────────────────────
  //
  /**
   * @description Marks a run as finished by updating its status, final output, and error
   * message, and stamping `Finished_At__c`. Called for both successful (`'Succeeded'`) and
   * hard-failed (`'Failed'`) terminations. If the finishing run is a sub-agent run (has a
   * `Parent_Run__c`), also resumes the suspended parent via `AgentEngine.resumeParentRun` —
   * this is the single choke point every termination path goes through, so a child that
   * hard-fails still wakes its parent instead of leaving it suspended forever. The resume
   * only fires on the first transition out of `'Running'`, so a duplicate `finishRun` call
   * cannot resume the parent twice.
   * @param runId Id of the `Agent_Run__c` to finish.
   * @param finalOutput Serialized final answer JSON, or `null` on failure.
   * @param status `'Succeeded'` or `'Failed'`.
   * @param errorMessage Error detail to store when `status` is `'Failed'`, otherwise `null`.
   */
  public static void finishRun(
    Id runId,
    String finalOutput,
    String status,
    String errorMessage
  ) {
    List<aao__Agent_Run__c> current = [
      SELECT
        aao__Status__c,
        Parent_Run__c,
        Parent_Step__c,
        aao__Agent__c,
        Session__c
      FROM aao__Agent_Run__c
      WHERE Id = :runId
      LIMIT 1
    ];

    aao__Agent_Run__c run = new aao__Agent_Run__c(
      Id = runId,
      aao__Status__c = status,
      aao__Final_Output__c = finalOutput,
      aao__Error_Message__c = errorMessage,
      aao__Finished_At__c = System.now()
    );
    update run;

    Boolean firstTermination =
      !current.isEmpty() && current[0].aao__Status__c == 'Running';

    // Release the conversation thread (Busy -> Active) now that this turn is over.
    // Sub-agent runs never hold a session; SessionService no-ops for them.
    if (firstTermination) {
      SessionService.onRunFinished(runId);
      UIEventPublisher.publishRunFinished(
        runId,
        current[0].Session__c,
        status,
        finalOutput,
        errorMessage
      );
      // Post-run learning (fact extraction / reflection). Sub-agent runs are skipped:
      // their transcript is part of the parent's task, not standalone knowledge.
      if (current[0].Parent_Run__c == null) {
        MemoryService.enqueueCapture(runId, current[0].aao__Agent__c, status);
      }
    }

    if (firstTermination && current[0].Parent_Run__c != null) {
      AgentEngine.resumeParentRun(
        current[0].Parent_Run__c,
        current[0].Parent_Step__c,
        runId,
        current[0].aao__Agent__c,
        finalOutput,
        status,
        errorMessage
      );
    }
  }
}
