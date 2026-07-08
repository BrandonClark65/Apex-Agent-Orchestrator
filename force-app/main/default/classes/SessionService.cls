/**
 * @description Owns the lifecycle of `Agent_Session__c` conversation threads: creating
 * sessions, seeding a new turn's history from the previous turn, and releasing the session
 * when a turn's run terminates. A session is `Busy` while a run is in flight — concurrent
 * sends are rejected by `AgentEngine.runAgentInSession` — and flips back to `Active` from
 * `ExecutionLogger.finishRun`, the single termination choke point. Sub-agent runs
 * (`Parent_Run__c` set) never touch sessions.
 * @group Agent Engine
 */
public with sharing class SessionService {
  // Title__c is Text(255); first user message is truncated to fit.
  private static final Integer MAX_TITLE_LENGTH = 255;

  /**
   * @description Creates a new `Active` session owned by the running user.
   * @param agentDeveloperName DeveloperName of the `Agent_Definition__mdt` this thread converses with.
   * @param firstMessage The first user message; truncated into `Title__c` for display.
   * @return Id of the new Agent_Session__c record.
   */
  public static Id startSession(
    String agentDeveloperName,
    String firstMessage
  ) {
    Agent_Session__c session = new Agent_Session__c(
      Agent__c = agentDeveloperName,
      User__c = UserInfo.getUserId(),
      Status__c = 'Active',
      Title__c = firstMessage == null
        ? null
        : firstMessage.abbreviate(MAX_TITLE_LENGTH),
      Turn_Count__c = 0,
      Last_Activity__c = System.now()
    );
    insert session;
    return session.Id;
  }

  /**
   * @description Loads the conversation history to seed a follow-up turn: the previous
   * turn's `History_Json__c` with the leading system message removed, so
   * `AgentEngine.runLLMStep` re-prepends a fresh system prompt built against the current
   * tool manifest. Returns an empty list for a session with no completed turns.
   * @param sessionId Id of the `Agent_Session__c` to load history for.
   * @return Prior conversation as LLMMessages, without a system message.
   */
  public static List<LLMMessage> loadSeedHistory(Id sessionId) {
    // LongTextArea fields can't be filtered in SOQL; find the newest turn that
    // actually persisted history in Apex instead.
    List<aao__Agent_Run__c> priorTurns = [
      SELECT aao__History_Json__c
      FROM aao__Agent_Run__c
      WHERE Session__c = :sessionId
      ORDER BY Turn_Number__c DESC
    ];

    String historyJson = null;
    for (aao__Agent_Run__c turn : priorTurns) {
      if (String.isNotBlank(turn.aao__History_Json__c)) {
        historyJson = turn.aao__History_Json__c;
        break;
      }
    }
    if (historyJson == null) {
      return new List<LLMMessage>();
    }

    List<LLMMessage> history = (List<LLMMessage>) JSON.deserialize(
      historyJson,
      List<LLMMessage>.class
    );

    while (!history.isEmpty() && history[0].role == 'system') {
      history.remove(0);
    }
    return history;
  }

  /**
   * @description Releases a session after one of its turns terminates: flips `Busy` back
   * to `Active`, increments `Turn_Count__c`, and stamps `Last_Activity__c`. No-op for runs
   * without a session or for sub-agent runs (`Parent_Run__c` set). Never throws — session
   * bookkeeping must not break run termination.
   * @param runId Id of the Agent_Run__c that just terminated.
   */
  public static void onRunFinished(Id runId) {
    try {
      List<aao__Agent_Run__c> runs = [
        SELECT Session__c, Parent_Run__c
        FROM aao__Agent_Run__c
        WHERE Id = :runId
        LIMIT 1
      ];
      if (
        runs.isEmpty() ||
        runs[0].Session__c == null ||
        runs[0].Parent_Run__c != null
      ) {
        return;
      }

      List<Agent_Session__c> sessions = [
        SELECT Status__c, Turn_Count__c
        FROM Agent_Session__c
        WHERE Id = :runs[0].Session__c
        LIMIT 1
        FOR UPDATE
      ];
      if (sessions.isEmpty() || sessions[0].Status__c == 'Closed') {
        return;
      }

      Decimal turns = sessions[0].Turn_Count__c == null
        ? 0
        : sessions[0].Turn_Count__c;
      update new Agent_Session__c(
        Id = sessions[0].Id,
        Status__c = 'Active',
        Turn_Count__c = turns + 1,
        Last_Activity__c = System.now()
      );
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'SessionService.onRunFinished failed for run ' +
          runId +
          ': ' +
          e.getMessage()
      );
    }
  }

  /**
   * @description Ends a conversation thread. Closed sessions reject new turns.
   * @param sessionId Id of the Agent_Session__c to close.
   */
  public static void closeSession(Id sessionId) {
    update new Agent_Session__c(Id = sessionId, Status__c = 'Closed');
  }
}
