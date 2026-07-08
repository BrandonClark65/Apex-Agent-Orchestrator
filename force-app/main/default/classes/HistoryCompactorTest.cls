/**
 * @description Tests `HistoryCompactor`: threshold gating, the compact operation
 * (system message preserved, oldest messages folded into an LLM summary, recent tail
 * kept verbatim), the `Summary` step row, and the session summary write. Uses
 * `LLMClientMock` for the summarization call.
 * @group Tests
 */
@IsTest
private class HistoryCompactorTest {
  private static List<LLMMessage> bigHistory(Integer messageCount) {
    List<LLMMessage> history = new List<LLMMessage>();
    history.add(new LLMMessage('system', 'You are a helpful agent.'));
    String filler = 'x'.repeat(4000);
    for (Integer i = 0; i < messageCount; i++) {
      String role = Math.mod(i, 2) == 0 ? 'user' : 'assistant';
      history.add(new LLMMessage(role, 'message ' + i + ': ' + filler));
    }
    return history;
  }

  @IsTest
  static void testNeedsCompactionGating() {
    List<LLMMessage> small = new List<LLMMessage>{
      new LLMMessage('system', 'prompt'),
      new LLMMessage('user', 'hi')
    };
    System.assertEquals(
      false,
      HistoryCompactor.needsCompaction(small, 90000),
      'small histories never compact'
    );

    List<LLMMessage> big = bigHistory(30);
    System.assertEquals(true, HistoryCompactor.needsCompaction(big, 90000));
    System.assertEquals(
      false,
      HistoryCompactor.needsCompaction(big, 999999),
      'threshold is respected'
    );
  }

  @IsTest
  static void testCompactIfNeededShrinksAndPreservesStructure() {
    LLMClientMock mock = new LLMClientMock();
    mock.addResponse('The user asked about accounts; 5 were found.');
    LLMClientFactory.setMock(mock);

    Id runId = ExecutionLogger.startRun('CRUD_Agent', '{}', 'Apex');
    List<LLMMessage> history = bigHistory(30);
    Integer originalSize = JSON.serialize(history).length();
    String lastOriginalContent = history[history.size() - 1].content;

    Test.startTest();
    List<LLMMessage> compacted = HistoryCompactor.compactIfNeeded(
      history,
      'Default_Memory',
      'OpenAI_GPT4',
      runId
    );
    Test.stopTest();

    System.assert(
      JSON.serialize(compacted).length() < originalSize,
      'compacted history must be smaller'
    );
    System.assertEquals(
      'system',
      compacted[0].role,
      'system message stays first'
    );
    System.assertEquals(
      'assistant',
      compacted[1].role,
      'summary message follows the system message'
    );
    System.assert(
      compacted[1].content.startsWith('[Conversation summary]'),
      'summary is marked'
    );
    System.assert(
      compacted[1].content.contains('5 were found'),
      'summary carries the LLM text'
    );
    System.assertEquals(
      lastOriginalContent,
      compacted[compacted.size() - 1].content,
      'most recent message kept verbatim'
    );

    List<aao__Agent_Step__c> summarySteps = [
      SELECT Id
      FROM aao__Agent_Step__c
      WHERE aao__Agent_Run__c = :runId AND aao__Step_Type__c = 'Summary'
    ];
    System.assertEquals(1, summarySteps.size(), 'Summary step logged');
  }

  @IsTest
  static void testNoOpBelowThreshold() {
    LLMClientMock mock = new LLMClientMock();
    LLMClientFactory.setMock(mock);

    Id runId = ExecutionLogger.startRun('CRUD_Agent', '{}', 'Apex');
    List<LLMMessage> history = new List<LLMMessage>{
      new LLMMessage('system', 'prompt'),
      new LLMMessage('user', 'hi'),
      new LLMMessage('assistant', 'hello'),
      new LLMMessage('user', 'thanks'),
      new LLMMessage('assistant', 'anytime')
    };

    List<LLMMessage> result = HistoryCompactor.compactIfNeeded(
      history,
      'Default_Memory',
      'OpenAI_GPT4',
      runId
    );

    System.assertEquals(history.size(), result.size(), 'unchanged');
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM aao__Agent_Step__c
        WHERE aao__Agent_Run__c = :runId
      ],
      'no step logged'
    );
  }

  @IsTest
  static void testWritesSessionSummary() {
    LLMClientMock mock = new LLMClientMock();
    mock.addResponse('Session recap text.');
    LLMClientFactory.setMock(mock);

    Id sessionId = SessionService.startSession('CRUD_Agent', 'hi');
    Id runId = ExecutionLogger.startRun('CRUD_Agent', '{}', 'Chat');
    update new aao__Agent_Run__c(
      Id = runId,
      Session__c = sessionId,
      Turn_Number__c = 1
    );

    Test.startTest();
    HistoryCompactor.compactIfNeeded(
      bigHistory(30),
      'Default_Memory',
      'OpenAI_GPT4',
      runId
    );
    Test.stopTest();

    Agent_Session__c session = [
      SELECT Summary__c
      FROM Agent_Session__c
      WHERE Id = :sessionId
    ];
    System.assert(
      session.Summary__c.contains('Session recap text.'),
      'rolling summary written to the session'
    );
  }

  @IsTest
  static void testFailureFallsBackToOriginalHistory() {
    // No mock responses queued -> the summarization call will throw inside compact.
    LLMClientMock mock = new LLMClientMock();
    LLMClientFactory.setMock(mock);

    Id runId = ExecutionLogger.startRun('CRUD_Agent', '{}', 'Apex');
    List<LLMMessage> history = bigHistory(30);

    List<LLMMessage> result = HistoryCompactor.compactIfNeeded(
      history,
      'Default_Memory',
      'OpenAI_GPT4',
      runId
    );

    System.assertEquals(
      history.size(),
      result.size(),
      'failed compaction returns the original history untouched'
    );
  }
}
