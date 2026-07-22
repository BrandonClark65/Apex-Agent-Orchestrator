/**
 * @description Tests `AgentChatApi`: server-side single-agent resolution (the customer never
 * supplies an agent), externalRef scoping on new and continued sessions, oversized/blank input
 * rejection, the config route, and the not-configured path. The async agent loop is not exercised
 * here (no `Test.stopTest`), so enqueued runs never execute — these tests cover the REST
 * boundary's routing, auth-scoping, and validation, not the engine.
 * @group Tests
 */
@IsTest
private class AgentChatApiTest {
  private static final String AGENT = 'Orchestrator_Agent';

  private static void setRequest(String method, String uri, String bodyJson) {
    RestRequest req = new RestRequest();
    req.httpMethod = method;
    req.requestURI = uri;
    if (bodyJson != null) {
      req.requestBody = Blob.valueOf(bodyJson);
    }
    RestContext.request = req;
    RestContext.response = new RestResponse();
  }

  private static Map<String, Object> responseBody() {
    return (Map<String, Object>) JSON.deserializeUntyped(
      RestContext.response.responseBody.toString()
    );
  }

  @IsTest
  static void testPostNewSessionUsesConfiguredAgent() {
    AgentChatApi.externalAgentOverride = AGENT;
    // Note: no 'agent' in the body — the customer cannot choose one.
    setRequest(
      'POST',
      '/services/apexrest/agent/message',
      JSON.serialize(
        new Map<String, Object>{
          'message' => 'hello there',
          'externalRef' => 'ext-1'
        }
      )
    );

    AgentChatApi.doPost();

    System.assertEquals(202, RestContext.response.statusCode);
    Id sessionId = (Id) responseBody().get('sessionId');
    Agent_Session__c session = [
      SELECT External_Ref__c, Agent__c
      FROM Agent_Session__c
      WHERE Id = :sessionId
    ];
    System.assertEquals('ext-1', session.External_Ref__c);
    System.assertEquals(AGENT, session.Agent__c);
  }

  @IsTest
  static void testPostIgnoresClientSuppliedAgent() {
    AgentChatApi.externalAgentOverride = AGENT;
    // A client tries to smuggle in a different agent; it must be ignored.
    setRequest(
      'POST',
      '/services/apexrest/agent/message',
      JSON.serialize(
        new Map<String, Object>{
          'agent' => 'Some_Other_Agent',
          'message' => 'hello',
          'externalRef' => 'ext-1'
        }
      )
    );

    AgentChatApi.doPost();

    System.assertEquals(202, RestContext.response.statusCode);
    Id sessionId = (Id) responseBody().get('sessionId');
    System.assertEquals(
      AGENT,
      [SELECT Agent__c FROM Agent_Session__c WHERE Id = :sessionId].Agent__c
    );
  }

  @IsTest
  static void testPostNotConfiguredReturns503() {
    // No override and no agent flagged Externally_Accessible in the org.
    setRequest(
      'POST',
      '/services/apexrest/agent/message',
      JSON.serialize(
        new Map<String, Object>{ 'message' => 'hello', 'externalRef' => 'ext-1' }
      )
    );

    AgentChatApi.doPost();

    System.assertEquals(503, RestContext.response.statusCode);
    System.assertEquals(0, [SELECT COUNT() FROM Agent_Session__c]);
  }

  @IsTest
  static void testPostRequiresExternalRef() {
    AgentChatApi.externalAgentOverride = AGENT;
    setRequest(
      'POST',
      '/services/apexrest/agent/message',
      JSON.serialize(new Map<String, Object>{ 'message' => 'hello' })
    );

    AgentChatApi.doPost();

    System.assertEquals(400, RestContext.response.statusCode);
    System.assert(
      String.valueOf(responseBody().get('error')).contains('externalRef')
    );
  }

  @IsTest
  static void testPostRejectsOversizedMessage() {
    AgentChatApi.externalAgentOverride = AGENT;
    setRequest(
      'POST',
      '/services/apexrest/agent/message',
      JSON.serialize(
        new Map<String, Object>{
          'message' => 'x'.repeat(8001),
          'externalRef' => 'ext-1'
        }
      )
    );

    AgentChatApi.doPost();

    System.assertEquals(400, RestContext.response.statusCode);
  }

  @IsTest
  static void testContinueSessionWrongRefRejected() {
    Agent_Session__c owned = new Agent_Session__c(
      Agent__c = AGENT,
      User__c = UserInfo.getUserId(),
      Status__c = 'Active',
      External_Ref__c = 'owner-1',
      Turn_Count__c = 0
    );
    insert owned;

    setRequest(
      'POST',
      '/services/apexrest/agent/message',
      JSON.serialize(
        new Map<String, Object>{
          'message' => 'let me in',
          'externalRef' => 'attacker',
          'sessionId' => owned.Id
        }
      )
    );

    AgentChatApi.doPost();

    System.assertEquals(403, RestContext.response.statusCode);
  }

  @IsTest
  static void testGetSessionScopedByExternalRef() {
    Agent_Session__c session = new Agent_Session__c(
      Agent__c = AGENT,
      User__c = UserInfo.getUserId(),
      Status__c = 'Active',
      Title__c = 'My thread',
      External_Ref__c = 'ext-1',
      Turn_Count__c = 0
    );
    insert session;

    // Matching externalRef -> 200
    setRequest('GET', '/services/apexrest/agent/session/' + session.Id, null);
    RestContext.request.params.put('externalRef', 'ext-1');
    AgentChatApi.doGet();
    System.assertEquals(200, RestContext.response.statusCode);
    System.assertEquals('Active', responseBody().get('status'));

    // Wrong externalRef -> 404
    setRequest('GET', '/services/apexrest/agent/session/' + session.Id, null);
    RestContext.request.params.put('externalRef', 'someone-else');
    AgentChatApi.doGet();
    System.assertEquals(404, RestContext.response.statusCode);
  }

  @IsTest
  static void testGetConfigReturnsAgentLabel() {
    AgentChatApi.externalAgentOverride = AGENT;
    setRequest('GET', '/services/apexrest/agent/config', null);
    AgentChatApi.doGet();

    System.assertEquals(200, RestContext.response.statusCode);
    System.assert(responseBody().containsKey('agentLabel'));
  }

  @IsTest
  static void testGetConfigNotConfiguredReturns503() {
    setRequest('GET', '/services/apexrest/agent/config', null);
    AgentChatApi.doGet();

    System.assertEquals(503, RestContext.response.statusCode);
  }

  private static void postMessage(String externalRef, String message) {
    setRequest(
      'POST',
      '/services/apexrest/agent/message',
      JSON.serialize(
        new Map<String, Object>{
          'message' => message,
          'externalRef' => externalRef
        }
      )
    );
    AgentChatApi.doPost();
  }

  @IsTest
  static void testRateLimitReturns429() {
    AgentChatApi.externalAgentOverride = AGENT;
    AgentChatApi.rateLimitMaxRequests = 2;

    postMessage('rl-1', 'first');
    System.assertEquals(202, RestContext.response.statusCode);
    postMessage('rl-1', 'second');
    System.assertEquals(202, RestContext.response.statusCode);

    // Third within the window exceeds the cap.
    postMessage('rl-1', 'third');
    System.assertEquals(429, RestContext.response.statusCode);
  }

  @IsTest
  static void testRateLimitIsPerExternalRef() {
    AgentChatApi.externalAgentOverride = AGENT;
    AgentChatApi.rateLimitMaxRequests = 1;

    postMessage('rl-a', 'one');
    System.assertEquals(202, RestContext.response.statusCode);
    postMessage('rl-a', 'two'); // caps this caller
    System.assertEquals(429, RestContext.response.statusCode);

    // A different caller is unaffected.
    postMessage('rl-b', 'one');
    System.assertEquals(202, RestContext.response.statusCode);
  }

  @IsTest
  static void testGetUnknownResource() {
    setRequest('GET', '/services/apexrest/agent/nope', null);
    AgentChatApi.doGet();

    System.assertEquals(404, RestContext.response.statusCode);
  }
}
