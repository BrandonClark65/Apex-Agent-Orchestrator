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
    mock.addResponse(
      '{"final":{"message":"Here are your accounts","count":3,"objectType":"Account"}}'
    );
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
    // The remaining final keys ride alongside as structured data for the LWC.
    System.assertNotEquals(
      null,
      state.messages[1].data,
      'structured payload should pass through the DTO'
    );
    System.assertEquals(3, state.messages[1].data.get('count'));
    System.assertEquals('Account', state.messages[1].data.get('objectType'));
    System.assert(
      !state.messages[1].data.containsKey('message'),
      'message stays in text, not duplicated into data'
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
  static void testGetAvailableAgentsHidesRestrictedAgents() {
    // CRUD_Agent now needs a custom permission this user does not hold; Orchestrator_Agent
    // is absent from the map, which means unrestricted.
    AgentAccess.setRequirements(
      new Map<String, String>{ 'CRUD_Agent' => 'AAO_Crud_Agent_Access' }
    );

    Set<String> visible = new Set<String>();
    for (
      AgentChatController.AgentOption opt : AgentChatController.getAvailableAgents()
    ) {
      visible.add(opt.developerName);
    }

    System.assert(
      !visible.contains('CRUD_Agent'),
      'restricted agent should not reach the picker'
    );
    System.assert(
      visible.contains('Orchestrator_Agent'),
      'unrestricted agents still show'
    );
  }

  @IsTest
  static void testSendMessageRejectsRestrictedAgent() {
    // The picker is filtered, but the real gate is the send: a hand-crafted call naming an
    // agent the picker never offered has to be refused too.
    AgentAccess.setRequirements(
      new Map<String, String>{ 'CRUD_Agent' => 'AAO_Crud_Agent_Access' }
    );

    Boolean threw = false;
    try {
      AgentChatController.sendMessage('CRUD_Agent', null, 'Find my accounts');
    } catch (AuraHandledException e) {
      threw = true;
    }
    System.assert(threw, 'sendMessage must refuse a restricted agent');
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Agent_Session__c],
      'no session is created for a refused agent'
    );
  }

  @IsTest
  static void testExistingSessionIsRefusedAfterAccessIsRevoked() {
    Id sessionId = SessionService.startSession('CRUD_Agent', 'hi');

    // Access revoked after the thread already exists.
    AgentAccess.setRequirements(
      new Map<String, String>{ 'CRUD_Agent' => 'AAO_Crud_Agent_Access' }
    );

    Boolean threw = false;
    try {
      AgentChatController.sendMessage(null, sessionId, 'another question');
    } catch (AuraHandledException e) {
      threw = true;
    }
    System.assert(
      threw,
      'the session pins the agent, so a revoked user cannot keep chatting in it'
    );
    System.assertEquals(
      'Active',
      [SELECT Status__c FROM Agent_Session__c WHERE Id = :sessionId].Status__c,
      'a refused turn must not leave the session locked Busy'
    );
  }

  @IsTest
  static void testCloseSession() {
    Id sessionId = SessionService.startSession('CRUD_Agent', 'hi');
    AgentChatController.closeSession(sessionId);
    System.assertEquals(
      'Closed',
      [SELECT Status__c FROM Agent_Session__c WHERE Id = :sessionId].Status__c
    );
  }
}
