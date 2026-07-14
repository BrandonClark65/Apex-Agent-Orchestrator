/**
 * @description `LLMClient` implementation for the OpenAI Responses API, on either platform:
 * OpenAI (`/v1/responses`) or Azure OpenAI (`/openai/responses?api-version=...` or
 * `/openai/v1/responses`). Constructed by `LLMClientFactory` from an `LLM_Provider__mdt`
 * record with `Provider_Type__c == 'Responses'`. The two platforms share the Responses wire
 * format; the auth difference (`Authorization: Bearer` vs `api-key`) lives entirely in the
 * named credential. `Model_Name__c` travels as `model` — on Azure that is the deployment
 * name, which the Responses API always takes in the body, never in the URL path.
 * @group LLM Integration
 */
public with sharing class OpenAIResponsesClient implements LLMClient {
  private aao__LLM_Provider__mdt provider;

  /**
   * @description Constructs a client bound to a specific provider configuration record.
   * @param provider The LLM_Provider__mdt record supplying model/deployment name, named credential, endpoint, and generation defaults.
   */
  public OpenAIResponsesClient(aao__LLM_Provider__mdt provider) {
    this.provider = provider;
  }

  /**
   * @description Sends the request to the Responses API endpoint and parses the response.
   * Conversation history maps onto `input` items (the Responses API accepts the same
   * system/user/assistant roles), and the reply is read from the `output` array's message
   * item. Requires `Database.AllowsCallouts`.
   * @param request Conversation history plus generation parameters; `maxTokens`/`temperature` fall back to the provider record's defaults when null.
   * @return The model's reply plus token usage, if reported.
   * @throws AgentException on a non-200 response, a failed/incomplete response, a refusal, or no message output.
   */
  public LLMResponse complete(LLMRequest request) {
    Http http = new Http();
    HttpRequest req = new HttpRequest();

    req.setEndpoint(
      'callout:' +
        provider.aao__Named_Credential__c +
        provider.aao__API_Endpoint__c
    );
    req.setMethod('POST');
    req.setHeader('Content-Type', 'application/json');

    Integer maxTokens = request.maxTokens != null
      ? request.maxTokens
      : (provider.aao__MaxTokens__c != null
          ? Integer.valueOf(provider.aao__MaxTokens__c)
          : 2048);
    Decimal temperature = request.temperature != null
      ? request.temperature
      : (provider.aao__Temperature__c != null
          ? provider.aao__Temperature__c
          : 0.0);

    List<Map<String, Object>> input = new List<Map<String, Object>>();
    for (LLMMessage message : request.messages) {
      input.add(
        new Map<String, Object>{
          'role' => message.role,
          'content' => message.content
        }
      );
    }

    // `store: false` — the Responses API persists responses server-side by default, but
    // the framework keeps its own history in Agent_Run__c and calls statelessly.
    Map<String, Object> body = new Map<String, Object>{
      'input' => input,
      'max_output_tokens' => maxTokens,
      'temperature' => temperature,
      'text' => new Map<String, Object>{
        'format' => new Map<String, String>{ 'type' => 'json_object' }
      },
      'store' => false
    };
    if (provider.aao__Model_Name__c != null) {
      body.put('model', provider.aao__Model_Name__c);
    }

    req.setBody(JSON.serialize(body));
    req.setTimeout(120000);

    HttpResponse res = http.send(req);

    if (res.getStatusCode() != 200) {
      throw new AgentException(
        'Responses API error ' + res.getStatusCode() + ': ' + res.getBody()
      );
    }

    Map<String, Object> rawBody = (Map<String, Object>) JSON.deserializeUntyped(
      res.getBody()
    );

    String status = (String) rawBody.get('status');
    if ('incomplete'.equals(status)) {
      Map<String, Object> details = (Map<String, Object>) rawBody.get(
        'incomplete_details'
      );
      String reason = details != null ? (String) details.get('reason') : null;
      if ('max_output_tokens'.equals(reason)) {
        throw new AgentException(
          'LLM response was truncated (incomplete: max_output_tokens). ' +
            'Increase MaxTokens__c in the LLM_Provider__mdt record or reduce context size.'
        );
      }
      throw new AgentException(
        'Responses API returned an incomplete response (' +
          reason +
          '): ' +
          res.getBody()
      );
    }
    if ('failed'.equals(status)) {
      throw new AgentException(
        'Responses API returned a failed response: ' + res.getBody()
      );
    }

    // The reply lives in the `output` array's message item(s); other item types
    // (e.g. `reasoning`) are skipped. Message content parts of type `output_text`
    // are concatenated; a `refusal` part throws.
    String text = null;
    List<Object> output = (List<Object>) rawBody.get('output');
    if (output != null) {
      for (Object itemObj : output) {
        Map<String, Object> item = (Map<String, Object>) itemObj;
        if (!'message'.equals((String) item.get('type'))) {
          continue;
        }
        List<Object> parts = (List<Object>) item.get('content');
        if (parts == null) {
          continue;
        }
        for (Object partObj : parts) {
          Map<String, Object> part = (Map<String, Object>) partObj;
          String partType = (String) part.get('type');
          if ('refusal'.equals(partType)) {
            throw new AgentException(
              'LLM refused the request: ' + (String) part.get('refusal')
            );
          }
          if ('output_text'.equals(partType)) {
            text = text == null
              ? (String) part.get('text')
              : text + (String) part.get('text');
          }
        }
      }
    }

    if (text == null) {
      throw new AgentException(
        'Responses API returned no message output: ' + res.getBody()
      );
    }

    LLMResponse response = new LLMResponse(text, res.getBody());

    Map<String, Object> rawUsage = (Map<String, Object>) rawBody.get('usage');
    if (rawUsage != null) {
      response.promptTokens = Integer.valueOf(rawUsage.get('input_tokens'));
      response.completionTokens = Integer.valueOf(
        rawUsage.get('output_tokens')
      );
      response.totalTokens = Integer.valueOf(rawUsage.get('total_tokens'));
    }

    return response;
  }
}
