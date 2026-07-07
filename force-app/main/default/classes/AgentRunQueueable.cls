/**
 * @description Queueable wrapper that runs a single LLM turn of an agent run
 * (`AgentEngine.runLLMStep`) in its own transaction. Implements `Database.AllowsCallouts`
 * since the LLM call is an HTTP callout; enqueued either directly by `AgentEngine.runAgent`
 * for the first step, or by `AgentStepEventTrigger` in response to an `Agent_Step_Event__e`
 * for subsequent steps.
 * @group Agent Engine
 */
public with sharing class AgentRunQueueable implements Queueable, Database.AllowsCallouts {
  private String agentDeveloperName;
  private String inputContextJson;
  private String triggerType;
  private Id runId;
  private List<LLMMessage> history;

  /**
   * @description Constructs the queueable with everything `AgentEngine.runLLMStep` needs to run.
   * @param agentDeveloperName DeveloperName of the Agent_Definition__mdt record being run.
   * @param inputContextJson Original run input JSON (only meaningful on the very first step).
   * @param triggerType Free-text trigger label carried through for logging/event propagation.
   * @param runId Id of the Agent_Run__c this step belongs to.
   * @param history Conversation history to resume from.
   */
  public AgentRunQueueable(
    String agentDeveloperName,
    String inputContextJson,
    String triggerType,
    Id runId,
    List<LLMMessage> history
  ) {
    this.agentDeveloperName = agentDeveloperName;
    this.inputContextJson = inputContextJson;
    this.triggerType = triggerType;
    this.runId = runId;
    this.history = history;
  }

  /**
   * @description Runs the LLM step; any uncaught exception hard-fails the run via `ExecutionLogger.finishRun`
   * rather than allowing the queueable to fail silently.
   * @param qc Queueable execution context provided by the platform.
   */
  public void execute(QueueableContext qc) {
    try {
      AgentEngine.runLLMStep(
        agentDeveloperName,
        inputContextJson,
        triggerType,
        runId,
        history
      );
    } catch (Exception e) {
      ExecutionLogger.finishRun(runId, null, 'Failed', e.getMessage());
    }
  }
}
