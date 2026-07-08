/**
 * @description Tests the M0 session foundation: `AgentEngine.runAgentInSession` +
 * `SessionService`. Follows the `AgentEngineTest` pattern — `LLMClientMock` supplies canned
 * model responses, and `Test.stopTest` flushes the single queueable hop a `{"final":...}`
 * response needs, so a whole turn (including `finishRun` releasing the session) completes
 * inside the test boundary. Later turns exercise only the synchronous half (locking,
 * seeding, run creation), since the event chain doesn't redeliver in tests.
 * @group Tests
 */
@IsTest
private class SessionServiceTest {
  private static Agent_Session__c getSession(Id sessionId) {
    return [
      SELECT Status__c, Agent__c, Title__c, Turn_Count__c, Last_Activity__c
      FROM Agent_Session__c
      WHERE Id = :sessionId
    ];
  }

  @IsTest
  static void testFirstTurnCreatesSessionAndReleasesIt() {
    LLMClientMock mock = new LLMClientMock();
    mock.addResponse('{"final":{"message":"Hello!"}}');
    LLMClientFactory.setMock(mock);

    Test.startTest();
    Id runId = AgentEngine.runAgentInSession(
      'CRUD_Agent',
      'Find my accounts',
      null,
      'Chat'
    );
    Test.stopTest();

    aao__Agent_Run__c run = [
      SELECT aao__Status__c, Session__c, Turn_Number__c, aao__Trigger_Type__c
      FROM aao__Agent_Run__c
      WHERE Id = :runId
    ];
    System.assertEquals('Succeeded', run.aao__Status__c);
    System.assertNotEquals(null, run.Session__c, 'run should be linked to a session');
    System.assertEquals(1, run.Turn_Number__c);

    Agent_Session__c session = getSession(run.Session__c);
    System.assertEquals('Active', session.Status__c, 'session released after the turn');
    System.assertEquals('CRUD_Agent', session.Agent__c);
    System.assertEquals('Find my accounts', session.Title__c);
    System.assertEquals(1, session.Turn_Count__c);
  }

  @IsTest
  static void testSecondTurnSeedsPriorHistoryWithoutSystemMessage() {
    LLMClientMock mock = new LLMClientMock();
    mock.addResponse('{"final":{"message":"Turn one answer"}}');
    LLMClientFactory.setMock(mock);

    Test.startTest();
    Id runId = AgentEngine.runAgentInSession(
      'CRUD_Agent',
      'First question',
      null,
      'Chat'
    );
    Test.stopTest();

    Id sessionId = [
      SELECT Session__c
      FROM aao__Agent_Run__c
      WHERE Id = :runId
    ]
    .Session__c;

    List<LLMMessage> seed = SessionService.loadSeedHistory(sessionId);
    System.assert(!seed.isEmpty(), 'prior turn history should seed the next turn');
    for (LLMMessage msg : seed) {
      System.assertNotEquals(
        'system',
        msg.role,
        'system message must be stripped so a fresh prompt is rebuilt'
      );
    }
    System.assertEquals('user', seed[0].role);
    System.assert(seed[0].content.contains('First question'));

    // Synchronous half of turn 2: locks the session, creates the linked run.
    Id run2Id = AgentEngine.runAgentInSession(
      'CRUD_Agent',
      'Follow-up question',
      sessionId,
      'Chat'
    );
    aao__Agent_Run__c run2 = [
      SELECT Session__c, Turn_Number__c
      FROM aao__Agent_Run__c
      WHERE Id = :run2Id
    ];
    System.assertEquals(sessionId, run2.Session__c);
    System.assertEquals(2, run2.Turn_Number__c);
    System.assertEquals('Busy', getSession(sessionId).Status__c);
  }

  @IsTest
  static void testBusySessionRejectsConcurrentSend() {
    Id sessionId = SessionService.startSession('CRUD_Agent', 'hi');
    update new Agent_Session__c(Id = sessionId, Status__c = 'Busy');

    try {
      AgentEngine.runAgentInSession('CRUD_Agent', 'second send', sessionId, 'Chat');
      System.assert(false, 'expected AuraHandledException for Busy session');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
  }

  @IsTest
  static void testClosedSessionRejectsNewTurn() {
    Id sessionId = SessionService.startSession('CRUD_Agent', 'hi');
    SessionService.closeSession(sessionId);

    try {
      AgentEngine.runAgentInSession('CRUD_Agent', 'another message', sessionId, 'Chat');
      System.assert(false, 'expected AuraHandledException for Closed session');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    System.assertEquals('Closed', getSession(sessionId).Status__c);
  }

  @IsTest
  static void testBlankMessageRejected() {
    try {
      AgentEngine.runAgentInSession('CRUD_Agent', '  ', null, 'Chat');
      System.assert(false, 'expected AuraHandledException for blank message');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
  }

  @IsTest
  static void testOnRunFinishedIgnoresSubAgentRuns() {
    Id sessionId = SessionService.startSession('CRUD_Agent', 'hi');
    update new Agent_Session__c(Id = sessionId, Status__c = 'Busy');

    Id parentRunId = ExecutionLogger.startRun('CRUD_Agent', '{}', 'Apex');
    Id childRunId = ExecutionLogger.startRun('CRUD_Agent', '{}', 'SubAgent');
    // A sub-agent run linked to the session must not release it — only the top-level turn does.
    update new aao__Agent_Run__c(
      Id = childRunId,
      Session__c = sessionId,
      Parent_Run__c = parentRunId
    );

    SessionService.onRunFinished(childRunId);
    System.assertEquals(
      'Busy',
      getSession(sessionId).Status__c,
      'sub-agent termination must not release the session'
    );
  }

  @IsTest
  static void testOnRunFinishedNoOpForSessionlessRun() {
    Id runId = ExecutionLogger.startRun('CRUD_Agent', '{}', 'Apex');
    // Must not throw for a one-shot run with no session.
    SessionService.onRunFinished(runId);
    System.assert(true);
  }

  @IsTest
  static void testLoadSeedHistoryEmptyForNewSession() {
    Id sessionId = SessionService.startSession('CRUD_Agent', 'hi');
    System.assertEquals(0, SessionService.loadSeedHistory(sessionId).size());
  }

  @IsTest
  static void testTitleTruncatedTo255() {
    String longMessage = 'x'.repeat(400);
    Id sessionId = SessionService.startSession('CRUD_Agent', longMessage);
    System.assertEquals(255, getSession(sessionId).Title__c.length());
  }
}
