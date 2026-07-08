/**
 * @description Publishes `Agent_UI_Event__e` platform events so UI components (chat,
 * run monitor) can react to run/step lifecycle in real time via `lightning/empApi`.
 * This is a fire-and-forget observability channel, deliberately separate from
 * `Agent_Step_Event__e` (the engine's control channel): publish failures are swallowed
 * and never affect the run, and per-step events can be disabled org-wide if platform
 * event allocations become a concern (`stepEventsEnabled`).
 * @group Agent Engine
 */
public with sharing class UIEventPublisher {
  /**
   * @description Kill switch for the chatty per-step events. `RunFinished` always
   * publishes regardless — UIs need at minimum the terminal signal, and pollers
   * cover the rest.
   */
  @TestVisible
  private static Boolean stepEventsEnabled = true;

  // Payload text fields ship truncated: the UI shows a live activity hint, not full data.
  private static final Integer MAX_PAYLOAD_FIELD_LENGTH = 500;

  /**
   * @description Publishes a `StepCompleted` event after a step row is logged.
   * @param runId Id of the Agent_Run__c the step belongs to.
   * @param sessionId Id of the run's Agent_Session__c, or null for one-shot runs.
   * @param stepType `Agent_Step__c.Step_Type__c` value (e.g. `'LLMCall'`, `'ToolCall'`).
   * @param toolName Tool DeveloperName for tool steps, else null.
   * @param status Step status (`'Completed'`, `'Failed'`, `'Pending'`).
   */
  public static void publishStepCompleted(
    Id runId,
    Id sessionId,
    String stepType,
    String toolName,
    String status
  ) {
    if (!stepEventsEnabled) {
      return;
    }
    publish(
      runId,
      sessionId,
      'StepCompleted',
      new Map<String, Object>{
        'stepType' => stepType,
        'toolName' => toolName,
        'status' => status
      }
    );
  }

  /**
   * @description Publishes the terminal `RunFinished` event. Always fires.
   * @param runId Id of the terminated Agent_Run__c.
   * @param sessionId Id of the run's Agent_Session__c, or null.
   * @param status Terminal run status (`'Succeeded'` / `'Failed'`).
   * @param finalOutput Serialized final answer, truncated into the payload.
   * @param errorMessage Error detail on failure, truncated into the payload.
   */
  public static void publishRunFinished(
    Id runId,
    Id sessionId,
    String status,
    String finalOutput,
    String errorMessage
  ) {
    publish(
      runId,
      sessionId,
      'RunFinished',
      new Map<String, Object>{
        'status' => status,
        'finalOutput' => truncate(finalOutput),
        'errorMessage' => truncate(errorMessage)
      }
    );
  }

  private static void publish(
    Id runId,
    Id sessionId,
    String eventType,
    Map<String, Object> payload
  ) {
    try {
      EventBus.publish(
        new Agent_UI_Event__e(
          Run_Id__c = runId,
          Session_Id__c = sessionId,
          Event_Type__c = eventType,
          Payload_Json__c = JSON.serialize(payload)
        )
      );
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'UIEventPublisher failed (' + eventType + '): ' + e.getMessage()
      );
    }
  }

  private static String truncate(String value) {
    return value == null ? null : value.abbreviate(MAX_PAYLOAD_FIELD_LENGTH);
  }
}
