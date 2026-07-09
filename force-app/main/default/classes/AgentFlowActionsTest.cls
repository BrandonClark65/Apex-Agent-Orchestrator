/**
 * @description Tests the Flow integration actions (`AgentFlowRunAgentAction`,
 * `AgentFlowSendMessageAction`, `AgentFlowGetRunResultAction`): one-shot runs, session
 * start/continue, result polling (succeeded/failed), bulk polling of multiple runs in one
 * call, and input validation. Uses `LLMClientMock` throughout.
 * @group Tests
 */
@IsTest
private class AgentFlowActionsTest {
  @IsTest
  static void testRunAgentStartsOneShotRun() {
    LLMClientMock mock = new LLMClientMock();
    mock.addResponse('{"final":{"message":"one-shot done"}}');
    LLMClientFactory.setMock(mock);

    AgentFlowRunAgentAction.Request request = new AgentFlowRunAgentAction.Request();
    request.agentDeveloperName = 'CRUD_Agent';
    request.inputContext = '{"task":"say hi"}';

    Test.startTest();
    List<AgentFlowRunAgentAction.Result> results = AgentFlowRunAgentAction.run(
      new List<AgentFlowRunAgentAction.Request>{ request }
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    System.assertNotEquals(null, results[0].runId);

    AgentFlowGetRunResultAction.Request pollRequest = new AgentFlowGetRunResultAction.Request();
    pollRequest.runId = results[0].runId;
    AgentFlowGetRunResultAction.Result status = AgentFlowGetRunResultAction.getResult(
      new List<AgentFlowGetRunResultAction.Request>{ pollRequest }
    )[0];

    System.assertEquals('Succeeded', status.status);
    System.assertEquals(true, status.isDone);
    System.assertEquals(true, status.isSuccess);
    System.assertEquals('one-shot done', status.finalMessage);
  }

  @IsTest
  static void testRunAgentRequiresAgentNameAndInput() {
    AgentFlowRunAgentAction.Request missingAgent = new AgentFlowRunAgentAction.Request();
    missingAgent.inputContext = 'hi';
    try {
      AgentFlowRunAgentAction.run(
        new List<AgentFlowRunAgentAction.Request>{ missingAgent }
      );
      System.assert(false, 'expected AgentException for missing agent name');
    } catch (AgentException e) {
      System.assert(e.getMessage().contains('Agent Developer Name'));
    }

    AgentFlowRunAgentAction.Request missingInput = new AgentFlowRunAgentAction.Request();
    missingInput.agentDeveloperName = 'CRUD_Agent';
    try {
      AgentFlowRunAgentAction.run(
        new List<AgentFlowRunAgentAction.Request>{ missingInput }
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

    AgentFlowSendMessageAction.Request first = new AgentFlowSendMessageAction.Request();
    first.agentDeveloperName = 'CRUD_Agent';
    first.message = 'Hello';

    Test.startTest();
    AgentFlowSendMessageAction.Result firstResult = AgentFlowSendMessageAction.send(
      new List<AgentFlowSendMessageAction.Request>{ first }
    )[0];
    Test.stopTest();

    System.assertNotEquals(null, firstResult.runId);
    System.assertNotEquals(null, firstResult.sessionId, 'a new session was created');

    // Second turn on the same session — LLMClientMock is reset per test method, so this
    // just verifies the sessionId round-trips correctly on a follow-up call.
    LLMClientMock mock2 = new LLMClientMock();
    mock2.addResponse('{"final":{"message":"second turn"}}');
    LLMClientFactory.setMock(mock2);

    AgentFlowSendMessageAction.Request second = new AgentFlowSendMessageAction.Request();
    second.agentDeveloperName = 'CRUD_Agent';
    second.message = 'Follow up';
    second.sessionId = firstResult.sessionId;

    AgentFlowSendMessageAction.Result secondResult = AgentFlowSendMessageAction.send(
      new List<AgentFlowSendMessageAction.Request>{ second }
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
    // test only needs to verify getResult's field mapping for a Failed run.
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

    AgentFlowGetRunResultAction.Request pollRequest = new AgentFlowGetRunResultAction.Request();
    pollRequest.runId = runId;
    AgentFlowGetRunResultAction.Result status = AgentFlowGetRunResultAction.getResult(
      new List<AgentFlowGetRunResultAction.Request>{ pollRequest }
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

    AgentFlowRunAgentAction.Request reqA = new AgentFlowRunAgentAction.Request();
    reqA.agentDeveloperName = 'CRUD_Agent';
    reqA.inputContext = '{"task":"A"}';
    AgentFlowRunAgentAction.Request reqB = new AgentFlowRunAgentAction.Request();
    reqB.agentDeveloperName = 'CRUD_Agent';
    reqB.inputContext = '{"task":"B"}';

    Test.startTest();
    List<AgentFlowRunAgentAction.Result> runResults = AgentFlowRunAgentAction.run(
      new List<AgentFlowRunAgentAction.Request>{ reqA, reqB }
    );
    Test.stopTest();

    AgentFlowGetRunResultAction.Request pollA = new AgentFlowGetRunResultAction.Request();
    pollA.runId = runResults[0].runId;
    AgentFlowGetRunResultAction.Request pollB = new AgentFlowGetRunResultAction.Request();
    pollB.runId = runResults[1].runId;

    List<AgentFlowGetRunResultAction.Result> statuses = AgentFlowGetRunResultAction.getResult(
      new List<AgentFlowGetRunResultAction.Request>{ pollA, pollB }
    );

    System.assertEquals(2, statuses.size());
    System.assertEquals('run A', statuses[0].finalMessage);
    System.assertEquals('run B', statuses[1].finalMessage);

    AgentFlowGetRunResultAction.Request blankRequest = new AgentFlowGetRunResultAction.Request();
    try {
      AgentFlowGetRunResultAction.getResult(
        new List<AgentFlowGetRunResultAction.Request>{ blankRequest }
      );
      System.assert(false, 'expected AgentException for missing Run Id');
    } catch (AgentException e) {
      System.assert(e.getMessage().contains('Run Id'));
    }
  }
}
