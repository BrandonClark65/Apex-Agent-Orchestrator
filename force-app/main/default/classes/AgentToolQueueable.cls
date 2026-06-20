public with sharing class AgentToolQueueable implements Queueable {

    private String agentDeveloperName;
    private String triggerType;
    private Id runId;
    private List<LLMMessage> history;
    private String toolName;
    private Map<String, Object> args;

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

    public void execute(QueueableContext qc) {

        try {
            AgentEngine.runToolStep(agentDeveloperName, triggerType, runId, history, toolName, args);

        } catch (Exception e) {
            ExecutionLogger.finishRun(runId, null, 'Failed', e.getMessage());
        }
    }
}
