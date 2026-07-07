/**
 * @description Test-only `LLMClient` that returns canned responses in FIFO order instead of
 * making a real callout. Register it via `LLMClientFactory.setMock`, queue responses in the
 * order the agent should receive them (typically tool-call responses followed by a final
 * `{"final":{...}}`), then run the agent under test. See `AgentEngineTest` for usage.
 * @group LLM Integration
 */
@IsTest
public class LLMClientMock implements LLMClient {
  private List<String> responses = new List<String>();
  private Integer index = 0;

  /**
   * @description Queues a raw JSON response string to be returned by the next `complete` call.
   * @param json Raw response text the mock will hand back verbatim as both `text` and `rawResponse`.
   */
  public void addResponse(String json) {
    responses.add(json);
  }

  /**
   * @description Returns the next queued response, ignoring the actual request contents.
   * @param request Ignored; present only to satisfy the `LLMClient` interface.
   * @return An LLMResponse wrapping the next queued JSON string.
   * @throws AgentException if no more responses have been queued.
   */
  public LLMResponse complete(LLMRequest request) {
    if (index >= responses.size()) {
      throw new AgentException('No more mock responses available.');
    }

    String text = responses[index++];
    return new LLMResponse(text, text);
  }
}
