/**
 * @description Tests `AgentFlowActions`: one-shot runs, session start/continue via
 * `sendAgentMessage`, result polling (running/succeeded/failed), bulk polling of multiple
 * runs in one call, and input validation. Uses `LLMClientMock` throughout.
 * @group Tests
 */
@IsTest
private class AgentFlowActionsTest {
  @IsTest
  static void testRunAgentStartsOneShotRun() {
    LLMClientMock mock = new LLMClientMock();
    mock.addResponse('{"final":{"message":"one-shot done"}}');
    LLMClientFactory.setMock(mock);

    AgentFlowActions.RunAgentRequest request = new AgentFlowActions.RunAgentRequest();
    request.agentDeveloperName = 'CRUD_Agent';
    request.inputContext = '{"task":"say hi"}';

    Test.startTest();
    List<AgentFlowActions.RunAgentResult> results = AgentFlowActions.runAgent(
      new List<AgentFlowActions.RunAgentRequest>{ request }
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    System.assertNotEquals(null, results[0].runId);

    AgentFlowActions.GetAgentRunResultRequest pollRequest = new AgentFlowActions.GetAgentRunResultRequest();
    pollRequest.runId = results[0].runId;
    AgentFlowActions.GetAgentRunResultResult status = AgentFlowActions.getAgentRunResult(
      new List<AgentFlowActions.GetAgentRunResultRequest>{ pollRequest }
    )[0];

    System.assertEquals('Succeeded', status.status);
    System.assertEquals(true, status.isDone);
    System.assertEquals(true, status.isSuccess);
    System.assertEquals('one-shot done', status.finalMessage);
  }

  @IsTest
  static void testRunAgentRequiresAgentNameAndInput() {
    AgentFlowActions.RunAgentRequest missingAgent = new AgentFlowActions.RunAgentRequest();
    missingAgent.inputContext = 'hi';
    try {
      AgentFlowActions.runAgent(
        new List<AgentFlowActions.RunAgentRequest>{ missingAgent }
      );
      System.assert(false, 'expected AgentException for missing agent name');
    } catch (AgentException e) {
      System.assert(e.getMessage().contains('Agent Developer Name'));
    }

    AgentFlowActions.RunAgentRequest missingInput = new AgentFlowActions.RunAgentRequest();
    missingInput.agentDeveloperName = 'CRUD_Agent';
    try {
      AgentFlowActions.runAgent(
        new List<AgentFlowActions.RunAgentRequest>{ missingInput }
      );
      System.assert(false, 'expected AgentException for missing input context');
    } catch (AgentException e) {
      System.assert(e.getMessage().contains('Input Context'));
    }
  }

  @IsTest
  static void testSendAgentMessageStartsNewSessionThenContinues() {
    LLMClientMock mock = new LLMClientMock();
    mock.addResponse('{"final":{"message":"first turn"}}');
    LLMClientFactory.setMock(mock);

    AgentFlowActions.SendAgentMessageRequest first = new AgentFlowActions.SendAgentMessageRequest();
    first.agentDeveloperName = 'CRUD_Agent';
    first.message = 'Hello';

    Test.startTest();
    AgentFlowActions.SendAgentMessageResult firstResult = AgentFlowActions.sendAgentMessage(
      new List<AgentFlowActions.SendAgentMessageRequest>{ first }
    )[0];
    Test.stopTest();

    System.assertNotEquals(null, firstResult.runId);
    System.assertNotEquals(null, firstResult.sessionId, 'a new session was created');

    // Second turn on the same session — LLMClientMock is reset per test method, so this
    // just verifies the sessionId round-trips correctly on a follow-up call.
    LLMClientMock mock2 = new LLMClientMock();
    mock2.addResponse('{"final":{"message":"second turn"}}');
    LLMClientFactory.setMock(mock2);

    AgentFlowActions.SendAgentMessageRequest second = new AgentFlowActions.SendAgentMessageRequest();
    second.agentDeveloperName = 'CRUD_Agent';
    second.message = 'Follow up';
    second.sessionId = firstResult.sessionId;

    AgentFlowActions.SendAgentMessageResult secondResult = AgentFlowActions.sendAgentMessage(
      new List<AgentFlowActions.SendAgentMessageRequest>{ second }
    )[0];

    System.assertEquals(
      firstResult.sessionId,
      secondResult.sessionId,
      'follow-up turn stays on the same session'
    );
  }

  @IsTest
  static void testGetAgentRunResultReflectsFailure() {
    // AgentEngine's retry-to-hard-fail path spans multiple platform-event hops that don't
    // fully drain within one Test.stopTest() (see AgentEngineTest's class doc) — simulate
    // the terminal state directly instead, the same way MemoryServiceTest does, since this
    // test only needs to verify getAgentRunResult's field mapping for a Failed run.
    Id runId = ExecutionLogger.startRun(
      'CRUD_Agent',
      '{"task":"trigger a failure"}',
      'Flow'
    );
    update new aao__Agent_Run__c(
      Id = runId,
      aao__Status__c = 'Failed',
      aao__Error_Message__c = 'Simulated failure'
    );

    AgentFlowActions.GetAgentRunResultRequest pollRequest = new AgentFlowActions.GetAgentRunResultRequest();
    pollRequest.runId = runId;
    AgentFlowActions.GetAgentRunResultResult status = AgentFlowActions.getAgentRunResult(
      new List<AgentFlowActions.GetAgentRunResultRequest>{ pollRequest }
    )[0];

    System.assertEquals('Failed', status.status);
    System.assertEquals(true, status.isDone);
    System.assertEquals(false, status.isSuccess);
    System.assertNotEquals(null, status.errorMessage);
  }

  @IsTest
  static void testGetAgentRunResultIsBulkSafeAndValidatesInput() {
    LLMClientMock mock = new LLMClientMock();
    mock.addResponse('{"final":{"message":"run A"}}');
    mock.addResponse('{"final":{"message":"run B"}}');
    LLMClientFactory.setMock(mock);

    AgentFlowActions.RunAgentRequest reqA = new AgentFlowActions.RunAgentRequest();
    reqA.agentDeveloperName = 'CRUD_Agent';
    reqA.inputContext = '{"task":"A"}';
    AgentFlowActions.RunAgentRequest reqB = new AgentFlowActions.RunAgentRequest();
    reqB.agentDeveloperName = 'CRUD_Agent';
    reqB.inputContext = '{"task":"B"}';

    Test.startTest();
    List<AgentFlowActions.RunAgentResult> runResults = AgentFlowActions.runAgent(
      new List<AgentFlowActions.RunAgentRequest>{ reqA, reqB }
    );
    Test.stopTest();

    AgentFlowActions.GetAgentRunResultRequest pollA = new AgentFlowActions.GetAgentRunResultRequest();
    pollA.runId = runResults[0].runId;
    AgentFlowActions.GetAgentRunResultRequest pollB = new AgentFlowActions.GetAgentRunResultRequest();
    pollB.runId = runResults[1].runId;

    List<AgentFlowActions.GetAgentRunResultResult> statuses = AgentFlowActions.getAgentRunResult(
      new List<AgentFlowActions.GetAgentRunResultRequest>{ pollA, pollB }
    );

    System.assertEquals(2, statuses.size());
    System.assertEquals('run A', statuses[0].finalMessage);
    System.assertEquals('run B', statuses[1].finalMessage);

    AgentFlowActions.GetAgentRunResultRequest blankRequest = new AgentFlowActions.GetAgentRunResultRequest();
    try {
      AgentFlowActions.getAgentRunResult(
        new List<AgentFlowActions.GetAgentRunResultRequest>{ blankRequest }
      );
      System.assert(false, 'expected AgentException for missing Run Id');
    } catch (AgentException e) {
      System.assert(e.getMessage().contains('Run Id'));
    }
  }
}
