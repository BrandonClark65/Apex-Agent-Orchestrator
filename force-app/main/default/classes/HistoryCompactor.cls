/**
 * @description Defends the 131,072-char `Agent_Run__c.History_Json__c` ceiling: when a
 * conversation's serialized history crosses the configured threshold, the oldest ~60% of
 * non-system messages are replaced by a single LLM-written summary message. Runs inside
 * `AgentEngine.runLLMStep` (the loop's only callout-enabled step). The summarization call
 * uses the memory config's `Maintenance_Provider__c` when set — cheap models summarize
 * fine — falling back to the agent's own provider. Compaction failures are swallowed and
 * the original history returned: a run must never die because its summary call failed.
 * @group Agent Engine
 */
public with sharing class HistoryCompactor {
  @TestVisible
  private static final Integer DEFAULT_THRESHOLD = 90000;

  // Fraction of non-system messages folded into the summary, oldest first.
  private static final Double COMPACT_FRACTION = 0.6;

  private static final String SUMMARY_PREFIX = '[Conversation summary] ';

  /**
   * @description Compacts the history if the agent's memory config demands it; otherwise
   * returns it unchanged. Also logs a `Summary` step and, when the run belongs to a
   * session, refreshes `Agent_Session__c.Summary__c`.
   * @param history Conversation history for the step about to run.
   * @param memoryConfigDeveloperName `Agent_Definition__mdt.MemoryConfig__c` value (may be blank).
   * @param fallbackProviderDeveloperName The agent's own `LLMProvider__c`, used when the config has no maintenance provider.
   * @param runId Id of the Agent_Run__c the step belongs to.
   * @return The (possibly compacted) history to continue with.
   */
  public static List<LLMMessage> compactIfNeeded(
    List<LLMMessage> history,
    String memoryConfigDeveloperName,
    String fallbackProviderDeveloperName,
    Id runId
  ) {
    try {
      aao__Memory_Config__mdt config = loadConfig(memoryConfigDeveloperName);
      Integer threshold = config != null &&
        config.Compaction_Threshold__c != null
        ? Integer.valueOf(config.Compaction_Threshold__c)
        : DEFAULT_THRESHOLD;

      if (!needsCompaction(history, threshold)) {
        return history;
      }

      String providerName = config != null &&
        String.isNotBlank(config.Maintenance_Provider__c)
        ? config.Maintenance_Provider__c
        : fallbackProviderDeveloperName;
      LLMClient client = LLMClientFactory.forProvider(providerName);

      return compact(history, client, runId);
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'HistoryCompactor skipped for run ' + runId + ': ' + e.getMessage()
      );
      return history;
    }
  }

  /**
   * @description True when the serialized history exceeds the threshold and there are
   * enough messages for a summary to help.
   * @param history Conversation history to measure.
   * @param threshold Serialized-size trigger in characters.
   * @return Whether compact should run.
   */
  public static Boolean needsCompaction(
    List<LLMMessage> history,
    Integer threshold
  ) {
    return countNonSystem(history) >= 4 &&
      JSON.serialize(history).length() > threshold;
  }

  /**
   * @description Replaces the oldest ~60% of non-system messages with one summary
   * assistant message written by `client`. Preserves the leading system message and the
   * most recent messages verbatim.
   * @param history Conversation history to compact.
   * @param client LLM client for the summarization call.
   * @param runId Id of the Agent_Run__c, for step logging and the session summary write.
   * @return New history: [system?] + summary + recent tail.
   */
  public static List<LLMMessage> compact(
    List<LLMMessage> history,
    LLMClient client,
    Id runId
  ) {
    List<LLMMessage> systemMessages = new List<LLMMessage>();
    List<LLMMessage> conversation = new List<LLMMessage>();
    for (LLMMessage msg : history) {
      if (msg.role == 'system') {
        systemMessages.add(msg);
      } else {
        conversation.add(msg);
      }
    }

    Integer cutoff = Integer.valueOf(conversation.size() * COMPACT_FRACTION);
    List<LLMMessage> toSummarize = new List<LLMMessage>();
    List<LLMMessage> toKeep = new List<LLMMessage>();
    for (Integer i = 0; i < conversation.size(); i++) {
      if (i < cutoff) {
        toSummarize.add(conversation[i]);
      } else {
        toKeep.add(conversation[i]);
      }
    }

    LLMRequest req = new LLMRequest();
    req.messages.add(
      new LLMMessage(
        'system',
        'You summarize agent conversation transcripts. Write a concise summary that ' +
          'preserves every fact needed to continue the conversation: user goals and ' +
          'constraints, record names/Ids that were read or written, tool outcomes, ' +
          'decisions made, and anything the user asked to be remembered. Respond with ' +
          'the summary text only.'
      )
    );
    req.messages.add(new LLMMessage('user', JSON.serialize(toSummarize)));

    LLMResponse res = client.complete(req);
    String summaryText = SUMMARY_PREFIX + res.text;

    ExecutionLogger.logStep(
      runId,
      new AgentStepLog(
        ExecutionLogger.nextStepNumber(runId),
        'Summary',
        JSON.serialize(req),
        res.rawResponse,
        null,
        null,
        'Completed',
        null
      )
    );
    writeSessionSummary(runId, summaryText);

    List<LLMMessage> compacted = new List<LLMMessage>();
    compacted.addAll(systemMessages);
    compacted.add(new LLMMessage('assistant', summaryText));
    compacted.addAll(toKeep);
    return compacted;
  }

  private static Integer countNonSystem(List<LLMMessage> history) {
    Integer count = 0;
    for (LLMMessage msg : history) {
      if (msg.role != 'system') {
        count++;
      }
    }
    return count;
  }

  private static aao__Memory_Config__mdt loadConfig(String developerName) {
    if (String.isBlank(developerName)) {
      return null;
    }
    List<aao__Memory_Config__mdt> configs = [
      SELECT Compaction_Threshold__c, Maintenance_Provider__c
      FROM aao__Memory_Config__mdt
      WHERE DeveloperName = :developerName
      LIMIT 1
    ];
    return configs.isEmpty() ? null : configs[0];
  }

  private static void writeSessionSummary(Id runId, String summaryText) {
    List<aao__Agent_Run__c> runs = [
      SELECT Session__c
      FROM aao__Agent_Run__c
      WHERE Id = :runId
      LIMIT 1
    ];
    if (!runs.isEmpty() && runs[0].Session__c != null) {
      update new Agent_Session__c(
        Id = runs[0].Session__c,
        Summary__c = summaryText
      );
    }
  }
}
