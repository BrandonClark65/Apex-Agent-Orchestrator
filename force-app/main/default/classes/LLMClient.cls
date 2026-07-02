/**
 * @description Interface every LLM provider client implements. Obtain an instance via
 * `LLMClientFactory.forProvider` rather than instantiating a concrete client directly, so
 * provider config (model, named credential, endpoint) stays driven by `LLM_Provider__mdt`.
 * @group LLM Integration
 */
public interface LLMClient {
  /**
   * @description Sends a chat completion request to the provider and returns its response.
   * Implementations that make HTTP callouts require a `Database.AllowsCallouts` execution
   * context (see `AgentRunQueueable`).
   * @param request Conversation history plus generation parameters.
   * @return The provider's response, including raw text and token usage where available.
   */
  LLMResponse complete(LLMRequest request);
}
