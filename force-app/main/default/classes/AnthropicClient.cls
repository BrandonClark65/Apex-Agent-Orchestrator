/**
 * @description `LLMClient` implementation for Anthropic's Messages API (`POST /v1/messages`).
 * Constructed by `LLMClientFactory` from an `LLM_Provider__mdt` record with
 * `Provider_Type__c == 'Anthropic'`; the callout target and credentials come from that
 * record's named credential (which must inject the `x-api-key` header) and endpoint.
 *
 * Wire-format notes vs the OpenAI client: Anthropic takes the system prompt as a top-level
 * `system` parameter (not a messages entry), requires the `anthropic-version` header and
 * `max_tokens`, returns content as an array of typed blocks, and current Claude models
 * (Opus 4.7+/Sonnet 5) reject sampling parameters — so `temperature` is intentionally
 * never sent; steer with prompting. Safety classifiers can return
 * `stop_reason == "refusal"`, surfaced as an AgentException so the engine's retry loop
 * treats it as a recoverable step error.
 * @group LLM Integration
 */
public with sharing class AnthropicClient implements LLMClient {
  private static final String ANTHROPIC_VERSION = '2023-06-01';

  private aao__LLM_Provider__mdt provider;

  /**
   * @description Constructs a client bound to a specific provider configuration record.
   * @param provider The LLM_Provider__mdt record supplying model, named credential, endpoint, and max tokens.
   */
  public AnthropicClient(aao__LLM_Provider__mdt provider) {
    this.provider = provider;
  }

  /**
   * @description Sends the request to Anthropic's Messages endpoint and parses the
   * response. Requires `Database.AllowsCallouts`.
   * @param request Conversation history plus generation parameters; `maxTokens` falls back to the provider record's default when null.
   * @return The model's reply plus token usage.
   * @throws AgentException on a non-200 response, a refusal, a truncated reply, or missing text content.
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
    req.setHeader('anthropic-version', ANTHROPIC_VERSION);

    Integer maxTokens = request.maxTokens != null
      ? request.maxTokens
      : (provider.aao__MaxTokens__c != null
          ? Integer.valueOf(provider.aao__MaxTokens__c)
          : 8192);

    // The system prompt travels as a top-level parameter; only user/assistant
    // messages go in the messages array. Consecutive same-role messages are
    // legal — the API combines them into one turn.
    String systemPrompt = null;
    List<Map<String, String>> messages = new List<Map<String, String>>();
    for (LLMMessage msg : request.messages) {
      if (msg.role == 'system') {
        systemPrompt = systemPrompt == null
          ? msg.content
          : systemPrompt + '\n\n' + msg.content;
      } else {
        messages.add(
          new Map<String, String>{ 'role' => msg.role, 'content' => msg.content }
        );
      }
    }

    Map<String, Object> body = new Map<String, Object>{
      'model' => provider.aao__Model_Name__c,
      'max_tokens' => maxTokens,
      'messages' => messages
    };
    if (String.isNotBlank(systemPrompt)) {
      body.put('system', systemPrompt);
    }

    req.setBody(JSON.serialize(body));
    req.setTimeout(120000); // 120s — large parallel contexts can be slow

    HttpResponse res = http.send(req);

    if (res.getStatusCode() != 200) {
      throw new AgentException(
        'Anthropic API error ' + res.getStatusCode() + ': ' + res.getBody()
      );
    }

    Map<String, Object> rawBody = (Map<String, Object>) JSON.deserializeUntyped(
      res.getBody()
    );

    // Check stop_reason before reading content: refusals return HTTP 200 with
    // empty (or partial) content.
    String stopReason = (String) rawBody.get('stop_reason');
    if ('refusal'.equals(stopReason)) {
      throw new AgentException(
        'Anthropic declined the request (stop_reason=refusal). ' +
          'Rephrase the task or route this agent to another provider.'
      );
    }
    if ('max_tokens'.equals(stopReason)) {
      throw new AgentException(
        'LLM response was truncated (stop_reason=max_tokens). ' +
          'Increase MaxTokens__c in the LLM_Provider__mdt record or reduce context size.'
      );
    }

    String text = extractText(rawBody);
    if (String.isBlank(text)) {
      throw new AgentException(
        'Anthropic returned no text content: ' + res.getBody()
      );
    }

    LLMResponse response = new LLMResponse(text, res.getBody());

    Map<String, Object> usage = (Map<String, Object>) rawBody.get('usage');
    if (usage != null) {
      response.promptTokens = Integer.valueOf(usage.get('input_tokens'));
      response.completionTokens = Integer.valueOf(usage.get('output_tokens'));
      response.totalTokens = response.promptTokens +
        response.completionTokens;
    }

    return response;
  }

  // Concatenates the text blocks from the content array, skipping thinking
  // and other non-text block types.
  private static String extractText(Map<String, Object> rawBody) {
    List<Object> blocks = (List<Object>) rawBody.get('content');
    if (blocks == null) {
      return null;
    }
    List<String> parts = new List<String>();
    for (Object blockObj : blocks) {
      Map<String, Object> block = (Map<String, Object>) blockObj;
      if ('text'.equals(block.get('type')) && block.get('text') != null) {
        parts.add((String) block.get('text'));
      }
    }
    return parts.isEmpty() ? null : String.join(parts, '');
  }
}
