/**
 * @description `LLMClient` implementation for Azure OpenAI chat completions. Constructed by
 * `LLMClientFactory` from an `LLM_Provider__mdt` record with `Provider_Type__c == 'Azure'`.
 * The wire format matches OpenAI's chat completions with two differences: auth uses the
 * `api-key` header, which the named credential must inject; and the `model` field carries
 * the Azure deployment name (`Model_Name__c`). Both Azure URL styles work — the legacy
 * deployments path (`/openai/deployments/<deployment>/chat/completions?api-version=...`),
 * which routes by URL and ignores the body's `model`, and the v1 path
 * (`/openai/v1/chat/completions`), which requires the deployment name in `model`.
 * @group LLM Integration
 */
public with sharing class AzureOpenAIClient implements LLMClient {
  private aao__LLM_Provider__mdt provider;

  /**
   * @description Constructs a client bound to a specific provider configuration record.
   * @param provider The LLM_Provider__mdt record supplying named credential, deployment endpoint, and generation defaults.
   */
  public AzureOpenAIClient(aao__LLM_Provider__mdt provider) {
    this.provider = provider;
  }

  /**
   * @description Sends the request to the Azure OpenAI deployment endpoint and parses the
   * chat-completions response. Requires `Database.AllowsCallouts`.
   * @param request Conversation history plus generation parameters; `maxTokens`/`temperature` fall back to the provider record's defaults when null.
   * @return The model's reply plus token usage, if reported.
   * @throws AgentException on a non-200 response, no choices returned, or a truncated (finish_reason=length) reply.
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

    // `model` is the Azure deployment name: required by the v1 endpoint, ignored by the
    // legacy deployments-path endpoint (which routes by the deployment in the URL).
    Map<String, Object> body = new Map<String, Object>{
      'messages' => request.messages,
      'max_tokens' => maxTokens,
      'temperature' => temperature,
      'response_format' => new Map<String, String>{ 'type' => 'json_object' }
    };
    if (provider.aao__Model_Name__c != null) {
      body.put('model', provider.aao__Model_Name__c);
    }

    req.setBody(JSON.serialize(body));
    req.setTimeout(120000);

    HttpResponse res = http.send(req);

    if (res.getStatusCode() != 200) {
      throw new AgentException(
        'Azure OpenAI API error ' + res.getStatusCode() + ': ' + res.getBody()
      );
    }

    Map<String, Object> rawBody = (Map<String, Object>) JSON.deserializeUntyped(
      res.getBody()
    );

    List<Object> choiceList = (List<Object>) rawBody.get('choices');
    if (choiceList == null || choiceList.isEmpty()) {
      throw new AgentException(
        'Azure OpenAI returned no choices in response: ' + res.getBody()
      );
    }
    Map<String, Object> choice = (Map<String, Object>) choiceList[0];

    if ('length'.equals((String) choice.get('finish_reason'))) {
      throw new AgentException(
        'LLM response was truncated (finish_reason=length). ' +
          'Increase MaxTokens__c in the LLM_Provider__mdt record or reduce context size.'
      );
    }

    Map<String, Object> message = (Map<String, Object>) choice.get('message');
    String text = message != null ? (String) message.get('content') : null;

    LLMResponse response = new LLMResponse(text, res.getBody());

    Map<String, Object> rawUsage = (Map<String, Object>) rawBody.get('usage');
    if (rawUsage != null) {
      response.promptTokens = Integer.valueOf(rawUsage.get('prompt_tokens'));
      response.completionTokens = Integer.valueOf(
        rawUsage.get('completion_tokens')
      );
      response.totalTokens = Integer.valueOf(rawUsage.get('total_tokens'));
    }

    return response;
  }
}
