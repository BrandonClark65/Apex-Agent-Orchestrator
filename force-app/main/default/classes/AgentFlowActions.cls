/**
 * @description Invocable Apex actions that let Salesforce Flow start and poll agent runs.
 * Agent runs always finish asynchronously (see `AgentEngine`), so a Flow that needs the
 * final answer must call `runAgent` or `sendAgentMessage` to kick off the run, then loop
 * on `getAgentRunResult` behind a Wait element until `isDone` comes back true.
 * @group Flow Integration
 */
public with sharing class AgentFlowActions {
  //
  // ───────────────────────────────────────────────────────────────
  // RUN AGENT (ONE-SHOT, NO SESSION)
  // ───────────────────────────────────────────────────────────────
  //
  public class RunAgentRequest {
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

  public class RunAgentResult {
    @InvocableVariable(label='Run Id')
    public Id runId;
  }

  /**
   * @description Starts a one-shot agent run (no conversation session) from Flow.
   * @param requests One request per bulk invocation.
   * @return One RunAgentResult per request, in the same order.
   */
  @InvocableMethod(
    label='Apex Agent: Run Agent'
    description='Starts a one-shot agent run (no conversation session). The run completes asynchronously — pass the returned Run Id to "Apex Agent: Get Run Result" to poll for completion.'
    category='Apex Agent Orchestrator'
  )
  public static List<RunAgentResult> runAgent(
    List<RunAgentRequest> requests
  ) {
    List<RunAgentResult> results = new List<RunAgentResult>();
    for (RunAgentRequest request : requests) {
      if (String.isBlank(request.agentDeveloperName)) {
        throw new AgentException('Agent Developer Name is required.');
      }
      if (String.isBlank(request.inputContext)) {
        throw new AgentException('Input Context is required.');
      }

      RunAgentResult result = new RunAgentResult();
      result.runId = AgentEngine.runAgent(
        request.agentDeveloperName,
        request.inputContext,
        String.isBlank(request.triggerType) ? 'Flow' : request.triggerType
      );
      results.add(result);
    }
    return results;
  }

  //
  // ───────────────────────────────────────────────────────────────
  // SEND AGENT MESSAGE (SESSION-BASED CHAT)
  // ───────────────────────────────────────────────────────────────
  //
  public class SendAgentMessageRequest {
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

  public class SendAgentMessageResult {
    @InvocableVariable(label='Run Id')
    public Id runId;

    @InvocableVariable(label='Session Id')
    public Id sessionId;
  }

  /**
   * @description Sends one turn of a conversation from Flow: starts a new session (blank
   * Session Id) or continues an existing one, mirroring `AgentChatController.sendMessage`.
   * @param requests One request per bulk invocation.
   * @return One SendAgentMessageResult per request, in the same order.
   */
  @InvocableMethod(
    label='Apex Agent: Send Chat Message'
    description='Sends one turn of a conversation: starts a new session (blank Session Id) or continues an existing one. The turn completes asynchronously — pass the returned Run Id to "Apex Agent: Get Run Result" to poll for completion.'
    category='Apex Agent Orchestrator'
  )
  public static List<SendAgentMessageResult> sendAgentMessage(
    List<SendAgentMessageRequest> requests
  ) {
    List<SendAgentMessageResult> results = new List<SendAgentMessageResult>();
    for (SendAgentMessageRequest request : requests) {
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

      SendAgentMessageResult result = new SendAgentMessageResult();
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

  //
  // ───────────────────────────────────────────────────────────────
  // GET RUN RESULT (POLLING)
  // ───────────────────────────────────────────────────────────────
  //
  public class GetAgentRunResultRequest {
    @InvocableVariable(
      label='Run Id'
      description='Run Id returned by "Run Agent" or "Send Chat Message".'
      required=true
    )
    public Id runId;
  }

  public class GetAgentRunResultResult {
    @InvocableVariable(label='Status')
    public String status;

    @InvocableVariable(
      label='Is Done'
      description='True once the run has left the Running state (Succeeded, Failed, or Cancelled).'
    )
    public Boolean isDone;

    @InvocableVariable(label='Is Success')
    public Boolean isSuccess;

    @InvocableVariable(
      label='Final Message'
      description='Human-readable answer extracted from the final output, when present.'
    )
    public String finalMessage;

    @InvocableVariable(
      label='Final Output JSON'
      description='Raw serialized final output.'
    )
    public String finalOutputJson;

    @InvocableVariable(label='Error Message')
    public String errorMessage;

    @InvocableVariable(label='Session Id')
    public Id sessionId;
  }

  /**
   * @description Checks the current status of one or more agent runs, for a Flow polling
   * loop. Bulk-safe: queries every requested run in one SOQL statement.
   * @param requests One request per bulk invocation.
   * @return One GetAgentRunResultResult per request, in the same order.
   */
  @InvocableMethod(
    label='Apex Agent: Get Run Result'
    description='Checks the current status of an agent run. Loop this behind a Wait element until Is Done is true, then read Final Message or Error Message.'
    category='Apex Agent Orchestrator'
  )
  public static List<GetAgentRunResultResult> getAgentRunResult(
    List<GetAgentRunResultRequest> requests
  ) {
    Set<Id> runIds = new Set<Id>();
    for (GetAgentRunResultRequest request : requests) {
      if (request.runId == null) {
        throw new AgentException('Run Id is required.');
      }
      runIds.add(request.runId);
    }

    Map<Id, aao__Agent_Run__c> runsById = new Map<Id, aao__Agent_Run__c>(
      [
        SELECT
          aao__Status__c,
          aao__Final_Output__c,
          aao__Error_Message__c,
          Session__c
        FROM aao__Agent_Run__c
        WHERE Id IN :runIds
      ]
    );

    List<GetAgentRunResultResult> results = new List<GetAgentRunResultResult>();
    for (GetAgentRunResultRequest request : requests) {
      aao__Agent_Run__c run = runsById.get(request.runId);
      if (run == null) {
        throw new AgentException(
          'No Agent Run found for Id ' + request.runId
        );
      }

      GetAgentRunResultResult result = new GetAgentRunResultResult();
      result.status = run.aao__Status__c;
      result.isDone = run.aao__Status__c != 'Running';
      result.isSuccess = run.aao__Status__c == 'Succeeded';
      result.finalOutputJson = run.aao__Final_Output__c;
      result.finalMessage = extractFinalMessage(run.aao__Final_Output__c);
      result.errorMessage = run.aao__Error_Message__c;
      result.sessionId = run.Session__c;
      results.add(result);
    }
    return results;
  }

  // Mirrors AgentChatController's soft contract: `final.message` carries the human-readable
  // answer; falls back to the raw serialized final output when absent or unparsable.
  private static String extractFinalMessage(String finalOutputJson) {
    if (String.isBlank(finalOutputJson)) {
      return null;
    }
    try {
      Object parsed = JSON.deserializeUntyped(finalOutputJson);
      if (parsed instanceof Map<String, Object>) {
        Object message = ((Map<String, Object>) parsed).get('message');
        if (message != null) {
          return String.valueOf(message);
        }
      }
    } catch (Exception e) {
      // Not JSON, or not the expected shape — fall through to the raw text.
    }
    return finalOutputJson;
  }
}
