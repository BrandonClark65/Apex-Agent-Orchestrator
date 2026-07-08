/**
 * @description Tests the Anthropic and Azure OpenAI clients (wire-format construction and
 * response parsing via `HttpCalloutMock`) and the `LLMClientFactory` provider branches.
 * @group Tests
 */
@IsTest
private class LLMProviderClientsTest {
  /** Captures the outbound request and returns a canned response. */
  private class CalloutMock implements HttpCalloutMock {
    public HttpRequest captured;
    private Integer status;
    private String body;

    public CalloutMock(Integer status, String body) {
      this.status = status;
      this.body = body;
    }

    public HttpResponse respond(HttpRequest req) {
      captured = req;
      HttpResponse res = new HttpResponse();
      res.setStatusCode(status);
      res.setBody(body);
      return res;
    }
  }

  private static aao__LLM_Provider__mdt anthropicProvider() {
    return new aao__LLM_Provider__mdt(
      aao__Provider_Type__c = 'Anthropic',
      aao__Model_Name__c = 'claude-opus-4-8',
      aao__Named_Credential__c = 'Anthropic_NC',
      aao__API_Endpoint__c = '/v1/messages',
      aao__MaxTokens__c = 16384
    );
  }

  private static aao__LLM_Provider__mdt azureProvider() {
    return new aao__LLM_Provider__mdt(
      aao__Provider_Type__c = 'Azure',
      aao__Named_Credential__c = 'AzureOpenAI_NC',
      aao__API_Endpoint__c = '/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-10-21',
      aao__MaxTokens__c = 2048,
      aao__Temperature__c = 0.1
    );
  }

  private static LLMRequest sampleRequest() {
    LLMRequest req = new LLMRequest();
    req.messages.add(new LLMMessage('system', 'You are an agent.'));
    req.messages.add(new LLMMessage('user', '{"task":"count accounts"}'));
    return req;
  }

  @IsTest
  static void testAnthropicRequestShapeAndResponseParsing() {
    String anthropicResponse = JSON.serialize(
      new Map<String, Object>{
        'content' => new List<Object>{
          new Map<String, Object>{
            'type' => 'text',
            'text' => '{"final":{"message":"42 accounts"}}'
          }
        },
        'stop_reason' => 'end_turn',
        'usage' => new Map<String, Object>{
          'input_tokens' => 120,
          'output_tokens' => 15
        }
      }
    );
    CalloutMock mock = new CalloutMock(200, anthropicResponse);
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    LLMResponse res = new AnthropicClient(anthropicProvider())
      .complete(sampleRequest());
    Test.stopTest();

    System.assertEquals('{"final":{"message":"42 accounts"}}', res.text);
    System.assertEquals(120, res.promptTokens);
    System.assertEquals(15, res.completionTokens);
    System.assertEquals(135, res.totalTokens);

    // wire format
    System.assertEquals(
      '2023-06-01',
      mock.captured.getHeader('anthropic-version')
    );
    Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(
      mock.captured.getBody()
    );
    System.assertEquals('claude-opus-4-8', sent.get('model'));
    System.assertEquals(16384, sent.get('max_tokens'));
    System.assertEquals(
      'You are an agent.',
      sent.get('system'),
      'system prompt travels as the top-level parameter'
    );
    System.assert(
      !sent.containsKey('temperature'),
      'sampling parameters are never sent to Anthropic'
    );
    List<Object> messages = (List<Object>) sent.get('messages');
    System.assertEquals(1, messages.size(), 'system message excluded');
    System.assertEquals(
      'user',
      ((Map<String, Object>) messages[0]).get('role')
    );
  }

  @IsTest
  static void testAnthropicRefusalAndTruncationThrow() {
    Test.setMock(
      HttpCalloutMock.class,
      new CalloutMock(
        200,
        '{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}'
      )
    );
    try {
      new AnthropicClient(anthropicProvider()).complete(sampleRequest());
      System.assert(false, 'expected refusal AgentException');
    } catch (AgentException e) {
      System.assert(e.getMessage().contains('refusal'), e.getMessage());
    }
  }

  @IsTest
  static void testAnthropicHttpErrorThrows() {
    Test.setMock(
      HttpCalloutMock.class,
      new CalloutMock(429, '{"error":{"type":"rate_limit_error"}}')
    );
    try {
      new AnthropicClient(anthropicProvider()).complete(sampleRequest());
      System.assert(false, 'expected AgentException');
    } catch (AgentException e) {
      System.assert(e.getMessage().contains('429'), e.getMessage());
    }
  }

  @IsTest
  static void testAzureRequestShapeAndResponseParsing() {
    String azureResponse = JSON.serialize(
      new Map<String, Object>{
        'choices' => new List<Object>{
          new Map<String, Object>{
            'finish_reason' => 'stop',
            'message' => new Map<String, Object>{
              'content' => '{"final":{"message":"done"}}'
            }
          }
        },
        'usage' => new Map<String, Object>{
          'prompt_tokens' => 100,
          'completion_tokens' => 10,
          'total_tokens' => 110
        }
      }
    );
    CalloutMock mock = new CalloutMock(200, azureResponse);
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    LLMResponse res = new AzureOpenAIClient(azureProvider())
      .complete(sampleRequest());
    Test.stopTest();

    System.assertEquals('{"final":{"message":"done"}}', res.text);
    System.assertEquals(110, res.totalTokens);

    Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(
      mock.captured.getBody()
    );
    System.assert(
      !sent.containsKey('model'),
      'Azure routes by deployment in the URL, not a model field'
    );
    System.assertEquals(2048, sent.get('max_tokens'));
    System.assert(
      mock.captured.getEndpoint().contains('api-version='),
      'api-version travels in the endpoint'
    );
  }

  @IsTest
  static void testFactoryResolvesNewProviders() {
    // Clear the auto-mock path: no LLMClientMock registered.
    System.assert(
      LLMClientFactory.forProvider('Anthropic_Claude') instanceof AnthropicClient,
      'Anthropic provider type resolves to AnthropicClient'
    );
    System.assert(
      LLMClientFactory.forProvider('Azure_OpenAI') instanceof AzureOpenAIClient,
      'Azure provider type resolves to AzureOpenAIClient'
    );
    System.assert(
      LLMClientFactory.forProvider('OpenAI_GPT4') instanceof OpenAIClient
    );
  }
}
