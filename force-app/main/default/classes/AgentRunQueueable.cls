public with sharing class AgentRunQueueable implements Queueable,  Database.AllowsCallouts {

    private String agentDeveloperName;
    private String inputContextJson;
    private String triggerType;
    private Id runId;

    public AgentRunQueueable(String agentDeveloperName, String inputContextJson, String triggerType, Id runId) {
        this.agentDeveloperName = agentDeveloperName;
        this.inputContextJson = inputContextJson;
        this.triggerType = triggerType;
        this.runId = runId;
    }

    public void execute(QueueableContext qc) {
        AgentEngine engine = new AgentEngine();
        engine.executeAgentRun(agentDeveloperName, inputContextJson, triggerType, runId);
    }
}
