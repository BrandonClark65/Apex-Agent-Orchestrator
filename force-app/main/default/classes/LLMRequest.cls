/**
 * @description Provider-agnostic input to `LLMClient.complete`: conversation history plus
 * generation parameters. Concrete clients (e.g. `OpenAIClient`) translate this into their
 * provider-specific request shape (e.g. `OpenAIRequestDTO`), falling back to
 * `LLM_Provider__mdt` defaults when `maxTokens`/`temperature` are left null.
 * @group LLM Integration
 */
public with sharing class LLMRequest {
  public List<LLMMessage> messages = new List<LLMMessage>();
  public Integer maxTokens;
  public Decimal temperature;

  /**
   * @description Constructs an empty request; populate `messages` before calling `complete`.
   */
  public LLMRequest() {
  }

  /**
   * @description Convenience constructor for a single-turn request.
   * @param userPrompt Text added as the sole 'user' message.
   */
  public LLMRequest(String userPrompt) {
    messages.add(new LLMMessage('user', userPrompt));
  }
}
