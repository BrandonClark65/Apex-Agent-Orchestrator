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
  // True when the tool started async work (a sub-agent run) instead of completing inline.
  // AgentEngine.runToolStep suspends the run instead of scheduling the next LLM step;
  // the run resumes when the async work finishes. See SubAgentTool.
  public Boolean pending;

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
    this.pending = false;
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

  /**
   * @description Builds a failed result that still carries a data payload. Use for batch
   * tools where nothing succeeded but the per-record breakdown is what the LLM needs to
   * recover — `error` discards `data`, which would hide which record/field actually failed.
   * @param message Human-readable error message shown to the LLM.
   * @param data Structured result payload explaining the failure.
   * @return A result with success = false.
   */
  public static AgentToolResult failure(
    String message,
    Map<String, Object> data
  ) {
    return new AgentToolResult(false, message, data);
  }

  /**
   * @description Builds a pending result for a tool that started async work (a sub-agent
   * run) rather than completing inline. The engine suspends the run until the work finishes.
   * @param message Human-readable summary of what was started.
   * @param data Must contain `childRunId` (Id of the sub-agent's Agent_Run__c) so the engine can link the child run back to this step.
   * @return A result with success = true and pending = true.
   */
  public static AgentToolResult pending(
    String message,
    Map<String, Object> data
  ) {
    AgentToolResult result = new AgentToolResult(true, message, data);
    result.pending = true;
    return result;
  }
}
