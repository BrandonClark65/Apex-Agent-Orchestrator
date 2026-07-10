/**
 * @description Invocable Apex action that starts a one-shot agent run (no conversation
 * session) from Salesforce Flow. Wraps `AgentEngine.runAgent`. The run completes
 * asynchronously — pass the returned Run Id to `AgentFlowGetRunResultAction` to poll for
 * completion. Only one `@InvocableMethod` is allowed per Apex class, so this is split out
 * from `AgentFlowSendMessageAction`/`AgentFlowGetRunResultAction` rather than combined.
 * @group Flow Integration
 */
public with sharing class AgentFlowRunAgentAction {
  public class Request {
    @InvocableVariable(
      label='Agent Developer Name'
      description='DeveloperName of the Agent_Definition__mdt record to run.'
      required=true
    )
    public String agentDeveloperName;

    @InvocableVariable(
      label='Input Context'
      description='JSON (or plain text) passed to the agent as its first user message.'
      required=true
    )
    public String inputContext;

    @InvocableVariable(
      label='Trigger Type'
      description='Free-text label stored for observability. Defaults to "Flow".'
    )
    public String triggerType;
  }

  public class Result {
    @InvocableVariable(label='Run Id')
    public Id runId;
  }

  /**
   * @description Starts a one-shot agent run (no conversation session) from Flow.
   * @param requests One request per bulk invocation.
   * @return One Result per request, in the same order.
   */
  @InvocableMethod(
    label='Apex Agent: Run Agent'
    description='Starts a one-shot agent run (no conversation session). The run completes asynchronously — pass the returned Run Id to "Apex Agent: Get Run Result" to poll for completion.'
    category='Apex Agent Orchestrator'
  )
  public static List<Result> run(List<Request> requests) {
    List<Result> results = new List<Result>();
    for (Request request : requests) {
      if (String.isBlank(request.agentDeveloperName)) {
        throw new AgentException('Agent Developer Name is required.');
      }
      if (String.isBlank(request.inputContext)) {
        throw new AgentException('Input Context is required.');
      }

      Result result = new Result();
      result.runId = AgentEngine.runAgent(
        request.agentDeveloperName,
        request.inputContext,
        String.isBlank(request.triggerType) ? 'Flow' : request.triggerType
      );
      results.add(result);
    }
    return results;
  }
}
