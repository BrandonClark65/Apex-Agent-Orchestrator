/**
 * @description Tests `AgentChatController` end-to-end with `LLMClientMock`: a full chat
 * turn through `sendMessage` (queueable flushed by `Test.stopTest`), session state
 * rendering (history parsed into user/assistant/tool chat messages with engine
 * instructions filtered out), the sidebar listing, and agent picker.
 * @group Tests
 */
@IsTest
private class AgentChatControllerTest {
  @IsTest
  static void testSendMessageAndSessionState() {
    LLMClientMock mock = new LLMClientMock();
    mock.addResponse(
      '{"tool":"QuerySalesforceTool","args":{"object":"Account"}}'
    );
    LLMClientFactory.setMock(mock);

    Test.startTest();
    AgentChatController.ChatTurnResult turn = AgentChatController.sendMessage(
      'CRUD_Agent',
      null,
      'Find my accounts'
    );
    Test.stopTest();

    System.assertNotEquals(null, turn.sessionId);
    System.assertNotEquals(null, turn.runId);
  }

  @IsTest
  static void testSessionStateRendersChatMessages() {
    LLMClientMock mock = new LLMClientMock();
    mock.addResponse('{"final":{"message":"Here are your accounts"}}');
    LLMClientFactory.setMock(mock);

    Test.startTest();
    AgentChatController.ChatTurnResult turn = AgentChatController.sendMessage(
      'CRUD_Agent',
      null,
      'Find my accounts'
    );
    Test.stopTest();

    AgentChatController.SessionState state = AgentChatController.getSessionState(
      turn.sessionId
    );
    System.assertEquals('Active', state.status, 'session released after turn');
    System.assertEquals('Succeeded', state.latestRunStatus);
    System.assertEquals('CRUD_Agent', state.agentDeveloperName);

    System.assertEquals(2, state.messages.size(), 'user + assistant');
    System.assertEquals('user', state.messages[0].role);
    System.assertEquals('Find my accounts', state.messages[0].text);
    System.assertEquals('assistant', state.messages[1].role);
    System.assertEquals(
      'Here are your accounts',
      state.messages[1].text,
      'final.message convention renders the human-readable answer'
    );
  }

  @IsTest
  static void testToolActivityRendersAsChipAndInstructionsHidden() {
    // Build a session whose persisted history includes a tool round-trip.
    Id sessionId = SessionService.startSession('CRUD_Agent', 'hi');
    Id runId = ExecutionLogger.startRun('CRUD_Agent', 'hi', 'Chat');
    List<LLMMessage> history = new List<LLMMessage>{
      new LLMMessage('system', 'prompt'),
      new LLMMessage('user', 'How many accounts do I have?'),
      new LLMMessage(
        'assistant',
        '{"tool":"QuerySalesforceTool","args":{"object":"Account"}}'
      ),
      new LLMMessage(
        'assistant',
        '{"tool":"QuerySalesforceTool","output":{"success":true,"message":"5 rows"}}'
      ),
      new LLMMessage(
        'user',
        '{"instruction":"Given the tool output above, decide..."}'
      ),
      new LLMMessage('assistant', '{"final":{"message":"You have 5"}}')
    };
    update new aao__Agent_Run__c(
      Id = runId,
      Session__c = sessionId,
      Turn_Number__c = 1,
      aao__History_Json__c = JSON.serialize(history)
    );

    AgentChatController.SessionState state = AgentChatController.getSessionState(
      sessionId
    );

    // user, tool-call chip, tool-output chip, final answer — instruction dropped
    System.assertEquals(4, state.messages.size());
    System.assertEquals('user', state.messages[0].role);
    System.assertEquals('tool', state.messages[1].role);
    System.assertEquals('QuerySalesforceTool', state.messages[1].toolName);
    System.assertEquals('tool', state.messages[2].role);
    System.assertEquals('assistant', state.messages[3].role);
    System.assertEquals('You have 5', state.messages[3].text);
  }

  @IsTest
  static void testGetMySessionsListsOwnSessions() {
    SessionService.startSession('CRUD_Agent', 'first thread');
    SessionService.startSession('CRUD_Agent', 'second thread');

    List<AgentChatController.SessionSummary> all = AgentChatController.getMySessions(
      null
    );
    System.assertEquals(2, all.size());

    List<AgentChatController.SessionSummary> filtered = AgentChatController.getMySessions(
      'CRUD_Agent'
    );
    System.assertEquals(2, filtered.size());
    System.assertEquals(
      0,
      AgentChatController.getMySessions('Orchestrator_Agent').size()
    );
  }

  @IsTest
  static void testGetAvailableAgents() {
    List<AgentChatController.AgentOption> agents = AgentChatController.getAvailableAgents();
    System.assert(!agents.isEmpty(), 'org has active demo agents');
    for (AgentChatController.AgentOption opt : agents) {
      System.assert(String.isNotBlank(opt.developerName));
      System.assert(String.isNotBlank(opt.label));
    }
  }

  @IsTest
  static void testCloseSession() {
    Id sessionId = SessionService.startSession('CRUD_Agent', 'hi');
    AgentChatController.closeSession(sessionId);
    System.assertEquals(
      'Closed',
      [SELECT Status__c FROM Agent_Session__c WHERE Id = :sessionId]
      .Status__c
    );
  }
}
