/**
 * @description Provider-agnostic result of `LLMClient.complete`. `text` is the model's raw
 * reply content, which `AgentEngine.runLLMStep` expects to be JSON matching the tool/tools/final
 * contract; `rawResponse` is the full provider payload, persisted as-is for observability.
 * @group LLM Integration
 */
public with sharing class LLMResponse {
  public String text;
  public String rawResponse;
  public Integer promptTokens;
  public Integer completionTokens;
  public Integer totalTokens;

  /**
   * @description Constructs a response; token usage fields are left null and set afterward
   * by the client if the provider reports usage.
   * @param text The model's reply content.
   * @param rawResponse The full raw response payload from the provider, for logging.
   */
  public LLMResponse(String text, String rawResponse) {
    this.text = text;
    this.rawResponse = rawResponse;
  }
}
