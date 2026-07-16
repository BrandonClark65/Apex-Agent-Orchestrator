/**
 * @description Plain data holder passed to `ExecutionLogger.logStep` describing one
 * `Agent_Step__c` row. The constructor accepts `Object` for the JSON-bearing fields and
 * serializes them itself, so callers can pass typed objects (e.g. an `LLMRequest`) or raw
 * strings interchangeably.
 * @group Agent Engine
 */
public class AgentStepLog {
  public Integer stepNumber;
  public String stepType;
  public String llmRequest;
  public String llmResponse;
  public String toolInput;
  public String toolOutput;
  public String status;
  public String toolName;

  // Token usage for LLM-backed steps ('LLMCall', 'Summary'); left null for tool steps and
  // set post-construction from the provider's LLMResponse. ExecutionLogger.logStep persists
  // these onto the Agent_Step__c row and rolls them up onto the parent Agent_Run__c.
  public Integer promptTokens;
  public Integer completionTokens;
  public Integer totalTokens;

  /**
   * @description Builds a step log entry, JSON-serializing any non-null `Object` arguments.
   * @param stepNumber 1-based position of this step within the run.
   * @param stepType 'LLMCall' or 'ToolCall'.
   * @param llmRequest Request sent to the LLM for this step, or null for tool steps.
   * @param llmResponse Raw response received from the LLM for this step, or null for tool steps.
   * @param toolInput Arguments passed to the tool for this step, or null for LLM steps.
   * @param toolOutput Result returned by the tool for this step, or null for LLM steps.
   * @param status 'Completed' or 'Failed'.
   * @param toolName DeveloperName of the tool invoked, or null for LLM steps.
   */
  public AgentStepLog(
    Integer stepNumber,
    String stepType,
    Object llmRequest,
    Object llmResponse,
    Object toolInput,
    Object toolOutput,
    String status,
    String toolName
  ) {
    this.stepNumber = stepNumber;
    this.stepType = stepType;
    this.llmRequest = llmRequest == null ? null : JSON.serialize(llmRequest);
    this.llmResponse = llmResponse == null ? null : JSON.serialize(llmResponse);
    this.toolInput = toolInput == null ? null : JSON.serialize(toolInput);
    this.toolOutput = toolOutput == null ? null : JSON.serialize(toolOutput);
    this.status = status;
    this.toolName = toolName;
  }
}
