/**
 * @description Standard return type for `AgentTool.run`. Serialized to JSON and appended to
 * conversation history, so `data` should contain only JSON-safe values. Prefer the
 * `success`/`error` static factory methods over the constructor for readability at call sites.
 * @group Agent Tools
 */
public class AgentToolResult {
  public Boolean success;
  public String message;
  public Map<String, Object> data;

  /**
   * @description Constructs a result directly; prefer `success`/`error` where possible.
   * @param success Whether the tool call succeeded.
   * @param message Human-readable summary shown to the LLM.
   * @param data Structured result payload, or null on error.
   */
  public AgentToolResult(
    Boolean success,
    String message,
    Map<String, Object> data
  ) {
    this.success = success;
    this.message = message;
    this.data = data;
  }

  /**
   * @description Builds a successful result.
   * @param message Human-readable summary shown to the LLM.
   * @param data Structured result payload.
   * @return A result with success = true.
   */
  public static AgentToolResult success(
    String message,
    Map<String, Object> data
  ) {
    return new AgentToolResult(true, message, data);
  }

  /**
   * @description Builds a failed result with no data payload.
   * @param message Human-readable error message shown to the LLM.
   * @return A result with success = false.
   */
  public static AgentToolResult error(String message) {
    return new AgentToolResult(false, message, null);
  }
}
