/**
 * @description Tests for `ExecutionLogger`'s loop-guard helpers — `hasIdenticalToolCall`
 * (duplicate consecutive tool-call detection) and `getConsecutiveErrorCount`. The
 * duplicate-call guard previously had no coverage, which let a regression survive: it
 * compared against the most-recent step of any type, but `runLLMStep` always logs the
 * current LLMCall step before invoking the guard, so it could never see a ToolCall and
 * never fired. These tests reproduce that exact ordering.
 * @group Agent Engine
 */
@IsTest
private class ExecutionLoggerTest {
  private static Id newRun() {
    // Blank trigger type falls back to 'Unknown' (a valid restricted-picklist value).
    return ExecutionLogger.startRun('TestAgent', '{"task":"x"}', '');
  }

  // Logs a ToolCall step exactly the way AgentEngine.runToolStep does: the caller passes
  // JSON.serialize(args), and AgentStepLog serializes a second time — so Tool_Input__c is
  // stored double-encoded. Reproducing that is essential; the guard must cope with it.
  private static void logToolStep(Id runId, String toolName, Map<String, Object> args) {
    ExecutionLogger.logStep(
      runId,
      new AgentStepLog(
        ExecutionLogger.nextStepNumber(runId),
        'ToolCall',
        null,
        null,
        JSON.serialize(args),
        JSON.serialize(new Map<String, Object>{ 'success' => true }),
        'Completed',
        toolName
      )
    );
  }

  private static void logLlmStep(Id runId, String status) {
    ExecutionLogger.logStep(
      runId,
      new AgentStepLog(
        ExecutionLogger.nextStepNumber(runId),
        'LLMCall',
        '{"req":1}',
        '{"resp":1}',
        null,
        null,
        status,
        null
      )
    );
  }

  private static Map<String, Object> updateArgs(Integer confidence) {
    // Build via a parsed JSON string so key ordering mirrors how args arrive in runLLMStep.
    return (Map<String, Object>) JSON.deserializeUntyped(
      '{"object":"Case","records":[{"id":"500000000000001","fields":{"Spam__c":true,"SpamConfidence__c":' +
      confidence +
      '}}]}'
    );
  }

  @IsTest
  static void guardFiresOnConsecutiveIdenticalToolCall() {
    Id runId = newRun();
    logToolStep(runId, 'UpdateRecordTool', updateArgs(88));
    // The LLMCall that re-emits the identical tool call is logged BEFORE the guard runs —
    // this is the ordering that used to defeat the guard entirely.
    logLlmStep(runId, 'Completed');

    Test.startTest();
    Boolean repeated = ExecutionLogger.hasIdenticalToolCall(
      runId,
      'UpdateRecordTool',
      updateArgs(88)
    );
    Test.stopTest();

    System.assert(
      repeated,
      'Guard must detect an identical UpdateRecordTool call even with an LLMCall step logged after the tool step'
    );
  }

  @IsTest
  static void guardIgnoresDifferentArgs() {
    Id runId = newRun();
    logToolStep(runId, 'UpdateRecordTool', updateArgs(88));
    logLlmStep(runId, 'Completed');

    System.assert(
      !ExecutionLogger.hasIdenticalToolCall(runId, 'UpdateRecordTool', updateArgs(90)),
      'Different args (confidence 88 vs 90) must not count as a repeat'
    );
  }

  @IsTest
  static void guardIgnoresDifferentTool() {
    Id runId = newRun();
    logToolStep(runId, 'UpdateRecordTool', updateArgs(88));
    logLlmStep(runId, 'Completed');

    System.assert(
      !ExecutionLogger.hasIdenticalToolCall(runId, 'CreateRecordTool', updateArgs(88)),
      'A different tool name must not count as a repeat'
    );
  }

  @IsTest
  static void guardComparesLastToolCallNotInterveningTool() {
    Id runId = newRun();
    logToolStep(runId, 'UpdateRecordTool', updateArgs(88));
    logToolStep(runId, 'DescribeObjectTool', new Map<String, Object>{ 'object' => 'Case' });
    logLlmStep(runId, 'Completed');

    // The most recent ToolCall is Describe, so re-calling Update with the old args is NOT
    // "twice in a row" and must be allowed.
    System.assert(
      !ExecutionLogger.hasIdenticalToolCall(runId, 'UpdateRecordTool', updateArgs(88)),
      'A tool call is only a repeat when it matches the immediately preceding tool call'
    );
    // Re-calling Describe with identical args IS a consecutive repeat.
    System.assert(
      ExecutionLogger.hasIdenticalToolCall(
        runId,
        'DescribeObjectTool',
        new Map<String, Object>{ 'object' => 'Case' }
      ),
      'Identical consecutive DescribeObjectTool call must be detected'
    );
  }

  @IsTest
  static void guardFalseWhenNoToolSteps() {
    Id runId = newRun();
    logLlmStep(runId, 'Completed');

    System.assert(
      !ExecutionLogger.hasIdenticalToolCall(runId, 'UpdateRecordTool', updateArgs(88)),
      'With no prior ToolCall step the guard must return false'
    );
  }

  @IsTest
  static void consecutiveErrorCountStopsAtFirstSuccess() {
    Id runId = newRun();
    logLlmStep(runId, 'Failed');
    logLlmStep(runId, 'Completed');
    logLlmStep(runId, 'Failed');
    logLlmStep(runId, 'Failed');

    System.assertEquals(
      2,
      ExecutionLogger.getConsecutiveErrorCount(runId),
      'Only the trailing run of Failed steps should be counted'
    );
  }
}
