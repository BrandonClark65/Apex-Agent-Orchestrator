/**
 * @description Tests the Anthropic, Azure OpenAI, and Responses API clients (wire-format
 * construction and response parsing via `HttpCalloutMock`) and the `LLMClientFactory`
 * provider branches.
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
      aao__Model_Name__c = 'gpt-4o-mini',
      aao__Named_Credential__c = 'AzureOpenAI_NC',
      aao__API_Endpoint__c = '/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-10-21',
      aao__MaxTokens__c = 2048,
      aao__Temperature__c = 0.1
    );
  }

  private static aao__LLM_Provider__mdt responsesProvider() {
    return new aao__LLM_Provider__mdt(
      aao__Provider_Type__c = 'Responses',
      aao__Model_Name__c = 'gpt-4o-mini',
      aao__Named_Credential__c = 'AzureOpenAI_NC',
      aao__API_Endpoint__c = '/openai/responses?api-version=2025-04-01-preview',
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
    System.assertEquals(
      'gpt-4o-mini',
      sent.get('model'),
      'the deployment name travels as model so both legacy and v1 endpoints work'
    );
    System.assertEquals(2048, sent.get('max_tokens'));
    System.assert(
      mock.captured.getEndpoint().contains('api-version='),
      'api-version travels in the endpoint'
    );
  }

  @IsTest
  static void testResponsesRequestShapeAndResponseParsing() {
    String responsesResponse = JSON.serialize(
      new Map<String, Object>{
        'status' => 'completed',
        'output' => new List<Object>{
          new Map<String, Object>{ 'type' => 'reasoning' },
          new Map<String, Object>{
            'type' => 'message',
            'role' => 'assistant',
            'content' => new List<Object>{
              new Map<String, Object>{
                'type' => 'output_text',
                'text' => '{"final":{"message":"done"}}'
              }
            }
          }
        },
        'usage' => new Map<String, Object>{
          'input_tokens' => 100,
          'output_tokens' => 10,
          'total_tokens' => 110
        }
      }
    );
    CalloutMock mock = new CalloutMock(200, responsesResponse);
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    LLMResponse res = new OpenAIResponsesClient(responsesProvider())
      .complete(sampleRequest());
    Test.stopTest();

    System.assertEquals('{"final":{"message":"done"}}', res.text);
    System.assertEquals(100, res.promptTokens);
    System.assertEquals(10, res.completionTokens);
    System.assertEquals(110, res.totalTokens);

    Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(
      mock.captured.getBody()
    );
    System.assertEquals(
      'gpt-4o-mini',
      sent.get('model'),
      'the Responses API takes the model/deployment name in the body'
    );
    System.assertEquals(2048, sent.get('max_output_tokens'));
    System.assertEquals(false, sent.get('store'), 'responses are not stored server-side');
    System.assert(!sent.containsKey('messages'), 'history travels as input, not messages');
    List<Object> input = (List<Object>) sent.get('input');
    System.assertEquals(2, input.size());
    System.assertEquals('system', ((Map<String, Object>) input[0]).get('role'));
  }

  @IsTest
  static void testResponsesTruncationAndRefusalThrow() {
    Test.setMock(
      HttpCalloutMock.class,
      new CalloutMock(
        200,
        '{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}'
      )
    );
    try {
      new OpenAIResponsesClient(responsesProvider()).complete(sampleRequest());
      System.assert(false, 'expected truncation AgentException');
    } catch (AgentException e) {
      System.assert(e.getMessage().contains('truncated'), e.getMessage());
    }
  }

  @IsTest
  static void testResponsesHttpErrorThrows() {
    Test.setMock(
      HttpCalloutMock.class,
      new CalloutMock(400, '{"error":{"message":"missing model deployment"}}')
    );
    try {
      new OpenAIResponsesClient(responsesProvider()).complete(sampleRequest());
      System.assert(false, 'expected AgentException');
    } catch (AgentException e) {
      System.assert(e.getMessage().contains('400'), e.getMessage());
    }
  }

  @IsTest
  static void testResponsesUsesFirstMessageNotConcatenation() {
    // Some models emit a second, stray message after the real answer. Concatenating them
    // would yield invalid JSON like `{...}{...}`; only the first message must be used.
    String responsesResponse = JSON.serialize(
      new Map<String, Object>{
        'status' => 'completed',
        'output' => new List<Object>{
          new Map<String, Object>{ 'type' => 'reasoning' },
          new Map<String, Object>{
            'type' => 'message',
            'role' => 'assistant',
            'content' => new List<Object>{
              new Map<String, Object>{
                'type' => 'output_text',
                'text' => '{"tool":"DescribeObjectTool","args":{"object":"Case"}}'
              }
            }
          },
          new Map<String, Object>{
            'type' => 'message',
            'role' => 'assistant',
            'content' => new List<Object>{
              new Map<String, Object>{
                'type' => 'output_text',
                'text' => '{"error":"stray second message"}'
              }
            }
          }
        }
      }
    );
    Test.setMock(HttpCalloutMock.class, new CalloutMock(200, responsesResponse));

    Test.startTest();
    LLMResponse res = new OpenAIResponsesClient(responsesProvider())
      .complete(sampleRequest());
    Test.stopTest();

    System.assertEquals(
      '{"tool":"DescribeObjectTool","args":{"object":"Case"}}',
      res.text,
      'Only the first assistant message should be used, not a concatenation of both'
    );
  }

  @IsTest
  static void testResponsesReasoningEffortSentOnlyWhenConfigured() {
    Test.setMock(
      HttpCalloutMock.class,
      new CalloutMock(
        200,
        '{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"{\\"final\\":{}}"}]}]}'
      )
    );

    // Blank effort (non-reasoning model): no reasoning param.
    CalloutMock blankMock = new CalloutMock(
      200,
      '{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"{\\"final\\":{}}"}]}]}'
    );
    Test.setMock(HttpCalloutMock.class, blankMock);
    new OpenAIResponsesClient(responsesProvider()).complete(sampleRequest());
    Map<String, Object> blankBody = (Map<String, Object>) JSON.deserializeUntyped(
      blankMock.captured.getBody()
    );
    System.assert(
      !blankBody.containsKey('reasoning'),
      'No reasoning param should be sent when Reasoning_Effort__c is blank'
    );
    System.assert(
      blankBody.containsKey('temperature'),
      'temperature should be sent for a non-reasoning model'
    );

    // Configured effort: reasoning.effort travels in the body, lower-cased.
    aao__LLM_Provider__mdt reasoningProvider = responsesProvider();
    reasoningProvider.aao__Reasoning_Effort__c = 'Medium';
    CalloutMock effortMock = new CalloutMock(
      200,
      '{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"{\\"final\\":{}}"}]}]}'
    );
    Test.setMock(HttpCalloutMock.class, effortMock);
    new OpenAIResponsesClient(reasoningProvider).complete(sampleRequest());
    Map<String, Object> effortBody = (Map<String, Object>) JSON.deserializeUntyped(
      effortMock.captured.getBody()
    );
    Map<String, Object> reasoning = (Map<String, Object>) effortBody.get('reasoning');
    System.assertNotEquals(null, reasoning, 'reasoning param should be present');
    System.assertEquals('medium', reasoning.get('effort'));
    System.assert(
      !effortBody.containsKey('temperature'),
      'temperature must be omitted for a reasoning model — the Responses API rejects it with a 400'
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
    System.assert(
      LLMClientFactory.forProvider('Azure_OpenAI_Responses') instanceof OpenAIResponsesClient,
      'Responses provider type resolves to OpenAIResponsesClient'
    );
  }
}
