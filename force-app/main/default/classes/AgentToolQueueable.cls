/**
 * @description Queueable wrapper that runs a single tool call (`AgentEngine.runToolStep`) in its
 * own transaction. Does not implement `Database.AllowsCallouts` — tool execution is intentionally
 * callout-free. Enqueued by `AgentStepEventTrigger` in response to a `'Tool'`-typed
 * `Agent_Step_Event__e`, including one event per call when the LLM requests parallel tool calls.
 * @group Agent Engine
 */
public with sharing class AgentToolQueueable implements Queueable {
  private String agentDeveloperName;
  private String triggerType;
  private Id runId;
  private List<LLMMessage> history;
  private String toolName;
  private Map<String, Object> args;

  /**
   * @description Constructs the queueable with everything `AgentEngine.runToolStep` needs to run.
   * @param agentDeveloperName DeveloperName of the Agent_Definition__mdt record being run.
   * @param triggerType Free-text trigger label carried through for logging/event propagation.
   * @param runId Id of the Agent_Run__c this step belongs to.
   * @param history Conversation history to append this tool call's result to.
   * @param toolName DeveloperName of the Agent_Tool_Definition__mdt to invoke.
   * @param args Tool arguments as parsed from the LLM's response JSON.
   */
  public AgentToolQueueable(
    String agentDeveloperName,
    String triggerType,
    Id runId,
    List<LLMMessage> history,
    String toolName,
    Map<String, Object> args
  ) {
    this.agentDeveloperName = agentDeveloperName;
    this.triggerType = triggerType;
    this.runId = runId;
    this.history = history;
    this.toolName = toolName;
    this.args = args;
  }

  /**
   * @description Runs the tool step; any uncaught exception hard-fails the run via `ExecutionLogger.finishRun`
   * rather than allowing the queueable to fail silently.
   * @param qc Queueable execution context provided by the platform.
   */
  public void execute(QueueableContext qc) {
    try {
      AgentEngine.runToolStep(
        agentDeveloperName,
        triggerType,
        runId,
        history,
        toolName,
        args
      );
    } catch (Exception e) {
      ExecutionLogger.finishRun(runId, null, 'Failed', e.getMessage());
    }
  }
}
