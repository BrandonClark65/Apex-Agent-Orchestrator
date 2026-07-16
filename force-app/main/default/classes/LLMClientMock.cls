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
  private List<Integer> promptTokens = new List<Integer>();
  private List<Integer> completionTokens = new List<Integer>();
  private List<Integer> totalTokens = new List<Integer>();
  private Integer index = 0;

  /**
   * @description Queues a raw JSON response string to be returned by the next `complete` call,
   * with no token usage reported.
   * @param json Raw response text the mock will hand back verbatim as both `text` and `rawResponse`.
   */
  public void addResponse(String json) {
    addResponse(json, null, null, null);
  }

  /**
   * @description Queues a raw JSON response along with the token usage the mock should report,
   * so tests can exercise the per-step / per-run token rollup.
   * @param json Raw response text handed back as both `text` and `rawResponse`.
   * @param prompt Prompt (input) tokens to report, or null.
   * @param completion Completion (output) tokens to report, or null.
   * @param total Total tokens to report, or null.
   */
  public void addResponse(
    String json,
    Integer prompt,
    Integer completion,
    Integer total
  ) {
    responses.add(json);
    promptTokens.add(prompt);
    completionTokens.add(completion);
    totalTokens.add(total);
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

    Integer i = index++;
    String text = responses[i];
    LLMResponse response = new LLMResponse(text, text);
    response.promptTokens = promptTokens[i];
    response.completionTokens = completionTokens[i];
    response.totalTokens = totalTokens[i];
    return response;
  }
}
