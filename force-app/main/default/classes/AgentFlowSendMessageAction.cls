/**
 * @description Invocable Apex action that sends one turn of a conversation from Salesforce
 * Flow: starts a new session (blank Session Id) or continues an existing one. Wraps
 * `AgentEngine.runAgentInSession`, mirroring `AgentChatController.sendMessage`. The turn
 * completes asynchronously — pass the returned Run Id to `AgentFlowGetRunResultAction` to
 * poll for completion. Only one `@InvocableMethod` is allowed per Apex class, so this is
 * split out from `AgentFlowRunAgentAction`/`AgentFlowGetRunResultAction` rather than combined.
 * @group Flow Integration
 */
public with sharing class AgentFlowSendMessageAction {
  public class Request {
    @InvocableVariable(
      label='Agent Developer Name'
      description='Agent to converse with. Ignored on follow-up turns — the session pins the agent.'
      required=true
    )
    public String agentDeveloperName;

    @InvocableVariable(
      label='Message'
      description='The user message for this turn.'
      required=true
    )
    public String message;

    @InvocableVariable(
      label='Session Id'
      description='Existing Agent_Session__c to continue, or blank to start a new conversation.'
    )
    public Id sessionId;

    @InvocableVariable(
      label='Trigger Type'
      description='Free-text label stored for observability. Defaults to "Flow".'
    )
    public String triggerType;
  }

  public class Result {
    @InvocableVariable(label='Run Id')
    public Id runId;

    @InvocableVariable(label='Session Id')
    public Id sessionId;
  }

  /**
   * @description Sends one turn of a conversation from Flow: starts a new session (blank
   * Session Id) or continues an existing one.
   * @param requests One request per bulk invocation.
   * @return One Result per request, in the same order.
   */
  @InvocableMethod(
    label='Apex Agent: Send Chat Message'
    description='Sends one turn of a conversation: starts a new session (blank Session Id) or continues an existing one. The turn completes asynchronously — pass the returned Run Id to "Apex Agent: Get Run Result" to poll for completion.'
    category='Apex Agent Orchestrator'
  )
  public static List<Result> send(List<Request> requests) {
    List<Result> results = new List<Result>();
    for (Request request : requests) {
      if (String.isBlank(request.agentDeveloperName)) {
        throw new AgentException('Agent Developer Name is required.');
      }
      if (String.isBlank(request.message)) {
        throw new AgentException('Message is required.');
      }

      Id runId = AgentEngine.runAgentInSession(
        request.agentDeveloperName,
        request.message,
        request.sessionId,
        String.isBlank(request.triggerType) ? 'Flow' : request.triggerType
      );

      Result result = new Result();
      result.runId = runId;
      result.sessionId = [
        SELECT Session__c
        FROM aao__Agent_Run__c
        WHERE Id = :runId
        LIMIT 1
      ]
      .Session__c;
      results.add(result);
    }
    return results;
  }
}
