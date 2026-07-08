/**
 * @description Completion handler for builder-initiated metadata deployments: publishes
 * an `Agent_UI_Event__e` with `Event_Type__c = 'DeployFinished'` and the deployment job
 * id in `Run_Id__c`, so `aaoAgentBuilder` (already subscribed for live progress) can show
 * success/failure without polling. Failure detail is carried in the payload.
 * @group UI
 */
public with sharing class AgentDeployCallback implements Metadata.DeployCallback {
  /**
   * @description Metadata API completion hook.
   * @param result Deployment outcome including component errors.
   * @param context Carries the deployment job id the UI is watching.
   */
  public void handleResult(
    Metadata.DeployResult result,
    Metadata.DeployCallbackContext context
  ) {
    Boolean succeeded = result != null &&
      result.status == Metadata.DeployStatus.SUCCEEDED;

    List<String> errors = new List<String>();
    if (
      result != null &&
      result.details != null &&
      result.details.componentFailures != null
    ) {
      for (
        Metadata.DeployMessage failure : result.details.componentFailures
      ) {
        errors.add(failure.fullName + ': ' + failure.problem);
      }
    }

    try {
      EventBus.publish(
        new Agent_UI_Event__e(
          Run_Id__c = context == null || context.getCallbackJobId() == null
            ? 'deploy'
            : String.valueOf(context.getCallbackJobId()).left(18),
          Event_Type__c = 'DeployFinished',
          Payload_Json__c = JSON.serialize(
            new Map<String, Object>{
              'succeeded' => succeeded,
              'errors' => errors
            }
          )
        )
      );
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'Deploy completion event failed: ' + e.getMessage()
      );
    }
  }
}
