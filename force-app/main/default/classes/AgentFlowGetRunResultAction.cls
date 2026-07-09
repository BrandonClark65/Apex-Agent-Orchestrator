/**
 * @description Invocable Apex action that checks the current status of one or more agent
 * runs, for a Salesforce Flow polling loop (Wait element) against the async runs started by
 * `AgentFlowRunAgentAction`/`AgentFlowSendMessageAction`. Only one `@InvocableMethod` is
 * allowed per Apex class, so this is split out from those rather than combined.
 * @group Flow Integration
 */
public with sharing class AgentFlowGetRunResultAction {
  public class Request {
    @InvocableVariable(
      label='Run Id'
      description='Run Id returned by "Run Agent" or "Send Chat Message".'
      required=true
    )
    public Id runId;
  }

  public class Result {
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
   * @return One Result per request, in the same order.
   */
  @InvocableMethod(
    label='Apex Agent: Get Run Result'
    description='Checks the current status of an agent run. Loop this behind a Wait element until Is Done is true, then read Final Message or Error Message.'
    category='Apex Agent Orchestrator'
  )
  public static List<Result> getResult(List<Request> requests) {
    Set<Id> runIds = new Set<Id>();
    for (Request request : requests) {
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

    List<Result> results = new List<Result>();
    for (Request request : requests) {
      aao__Agent_Run__c run = runsById.get(request.runId);
      if (run == null) {
        throw new AgentException(
          'No Agent Run found for Id ' + request.runId
        );
      }

      Result result = new Result();
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
