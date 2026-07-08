/**
 * @description `@AuraEnabled` backend for the `aaoAgentChat` LWC suite. Returns typed DTOs
 * only — never raw SObjects — so 128KB history blobs are parsed and reduced server-side
 * before crossing the wire. Sending a message delegates to `AgentEngine.runAgentInSession`;
 * progress arrives via `Agent_UI_Event__e` (empApi) with `getSessionState` polling as the
 * fallback.
 * @group UI
 */
public with sharing class AgentChatController {
  /**
   * @description Lists active agents for the chat agent picker.
   * @return One AgentOption per `Agent_Definition__mdt` with `IsActive__c = true`.
   */
  @AuraEnabled(cacheable=true)
  public static List<AgentOption> getAvailableAgents() {
    List<AgentOption> options = new List<AgentOption>();
    for (aao__Agent_Definition__mdt def : [
      SELECT DeveloperName, MasterLabel, aao__Goal__c
      FROM aao__Agent_Definition__mdt
      WHERE aao__IsActive__c = TRUE
      ORDER BY MasterLabel
    ]) {
      AgentOption opt = new AgentOption();
      opt.developerName = def.DeveloperName;
      opt.label = def.MasterLabel;
      opt.goal = def.aao__Goal__c;
      options.add(opt);
    }
    return options;
  }

  /**
   * @description Sends one chat message: starts a new session (null sessionId) or the next
   * turn of an existing one via `AgentEngine.runAgentInSession`.
   * @param agentDeveloperName Agent to converse with (ignored on follow-ups — the session pins the agent).
   * @param sessionId Existing session to continue, or null for a new thread.
   * @param message The user's message.
   * @return Ids of the session and the in-flight run for this turn.
   */
  @AuraEnabled
  public static ChatTurnResult sendMessage(
    String agentDeveloperName,
    Id sessionId,
    String message
  ) {
    Id runId = AgentEngine.runAgentInSession(
      agentDeveloperName,
      message,
      sessionId,
      'Chat'
    );

    ChatTurnResult result = new ChatTurnResult();
    result.runId = runId;
    result.sessionId = [
      SELECT Session__c
      FROM aao__Agent_Run__c
      WHERE Id = :runId
      LIMIT 1
    ]
    .Session__c;
    return result;
  }

  /**
   * @description Loads a session's display state: status plus the conversation rendered as
   * chat messages (user bubbles, assistant answers, tool-activity chips). Engine-injected
   * instruction messages are filtered out.
   * @param sessionId Id of the Agent_Session__c to load.
   * @return SessionState DTO for the chat thread.
   */
  @AuraEnabled
  public static SessionState getSessionState(Id sessionId) {
    Agent_Session__c session = [
      SELECT Status__c, Agent__c, Title__c, Turn_Count__c
      FROM Agent_Session__c
      WHERE Id = :sessionId
      LIMIT 1
    ];

    SessionState state = new SessionState();
    state.sessionId = sessionId;
    state.status = session.Status__c;
    state.agentDeveloperName = session.Agent__c;
    state.title = session.Title__c;
    state.messages = toChatMessages(SessionService.loadSeedHistory(sessionId));

    List<aao__Agent_Run__c> latestRuns = [
      SELECT aao__Status__c, aao__Error_Message__c
      FROM aao__Agent_Run__c
      WHERE Session__c = :sessionId
      ORDER BY Turn_Number__c DESC
      LIMIT 1
    ];
    if (!latestRuns.isEmpty()) {
      state.latestRunStatus = latestRuns[0].aao__Status__c;
      state.latestRunError = latestRuns[0].aao__Error_Message__c;
    }
    return state;
  }

  /**
   * @description Lists the running user's sessions for the sidebar, newest activity first.
   * @param agentDeveloperName Optional filter to one agent; null returns all.
   * @return Up to 50 SessionSummary rows.
   */
  @AuraEnabled
  public static List<SessionSummary> getMySessions(String agentDeveloperName) {
    String userId = UserInfo.getUserId();
    List<Agent_Session__c> sessions;
    if (String.isBlank(agentDeveloperName)) {
      sessions = [
        SELECT Agent__c, Status__c, Title__c, Turn_Count__c, Last_Activity__c
        FROM Agent_Session__c
        WHERE User__c = :userId
        ORDER BY Last_Activity__c DESC NULLS LAST
        LIMIT 50
      ];
    } else {
      sessions = [
        SELECT Agent__c, Status__c, Title__c, Turn_Count__c, Last_Activity__c
        FROM Agent_Session__c
        WHERE User__c = :userId AND Agent__c = :agentDeveloperName
        ORDER BY Last_Activity__c DESC NULLS LAST
        LIMIT 50
      ];
    }

    List<SessionSummary> summaries = new List<SessionSummary>();
    for (Agent_Session__c s : sessions) {
      SessionSummary summary = new SessionSummary();
      summary.sessionId = s.Id;
      summary.agentDeveloperName = s.Agent__c;
      summary.status = s.Status__c;
      summary.title = s.Title__c;
      summary.turnCount = s.Turn_Count__c == null
        ? 0
        : Integer.valueOf(s.Turn_Count__c);
      summary.lastActivity = s.Last_Activity__c;
      summaries.add(summary);
    }
    return summaries;
  }

  /**
   * @description Closes a session so it rejects further turns.
   * @param sessionId Id of the Agent_Session__c to close.
   */
  @AuraEnabled
  public static void closeSession(Id sessionId) {
    SessionService.closeSession(sessionId);
  }

  //
  // ───────────────────────────────────────────────────────────────
  // History -> chat message rendering
  // ───────────────────────────────────────────────────────────────
  //

  /**
   * @description Converts engine history into displayable chat messages. History shapes:
   * user messages are either real user text or engine `{"instruction":...}` prompts (skipped);
   * assistant messages are the model contract (`final` -> answer bubble, `tool`/`tools` ->
   * "calling tool" chips) or the engine's tool-output wrapper (`{"tool":...,"output":...}` ->
   * tool-result chip).
   */
  private static List<ChatMessage> toChatMessages(List<LLMMessage> history) {
    List<ChatMessage> messages = new List<ChatMessage>();

    for (LLMMessage msg : history) {
      if (msg.role == 'system' || String.isBlank(msg.content)) {
        continue;
      }

      Map<String, Object> parsed = tryParseObject(msg.content);

      if (msg.role == 'user') {
        if (parsed != null && parsed.containsKey('instruction')) {
          continue; // engine-injected steering prompt, not the human
        }
        messages.add(chatMessage('user', msg.content, null));
        continue;
      }

      // assistant
      if (parsed == null) {
        messages.add(chatMessage('assistant', msg.content, null));
        continue;
      }
      if (parsed.containsKey('final')) {
        messages.add(
          chatMessage('assistant', extractFinalText(parsed), null)
        );
      } else if (parsed.containsKey('output')) {
        messages.add(
          chatMessage('tool', null, String.valueOf(parsed.get('tool')))
        );
      } else if (parsed.containsKey('tool')) {
        messages.add(
          chatMessage('tool', null, String.valueOf(parsed.get('tool')))
        );
      } else if (parsed.containsKey('tools')) {
        for (Object callObj : (List<Object>) parsed.get('tools')) {
          Map<String, Object> call = (Map<String, Object>) callObj;
          messages.add(
            chatMessage('tool', null, String.valueOf(call.get('tool')))
          );
        }
      } else {
        messages.add(chatMessage('assistant', msg.content, null));
      }
    }
    return messages;
  }

  // Soft contract with demo agent prompts: `final.message` carries the human-readable
  // answer; anything else falls back to the serialized final object.
  private static String extractFinalText(Map<String, Object> parsed) {
    Map<String, Object> finalResult = (Map<String, Object>) parsed.get('final');
    if (finalResult.containsKey('message')) {
      return String.valueOf(finalResult.get('message'));
    }
    return JSON.serializePretty(finalResult);
  }

  private static Map<String, Object> tryParseObject(String content) {
    try {
      Object raw = JSON.deserializeUntyped(content);
      return raw instanceof Map<String, Object>
        ? (Map<String, Object>) raw
        : null;
    } catch (Exception e) {
      return null;
    }
  }

  private static ChatMessage chatMessage(
    String role,
    String text,
    String toolName
  ) {
    ChatMessage msg = new ChatMessage();
    msg.role = role;
    msg.text = text;
    msg.toolName = toolName;
    return msg;
  }

  //
  // ───────────────────────────────────────────────────────────────
  // DTOs
  // ───────────────────────────────────────────────────────────────
  //

  /** @description Agent picker entry. */
  public class AgentOption {
    @AuraEnabled
    public String developerName;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String goal;
  }

  /** @description Result of sending one chat message. */
  public class ChatTurnResult {
    @AuraEnabled
    public Id sessionId;
    @AuraEnabled
    public Id runId;
  }

  /** @description One rendered chat entry: `role` is `user`, `assistant`, or `tool` (activity chip). */
  public class ChatMessage {
    @AuraEnabled
    public String role;
    @AuraEnabled
    public String text;
    @AuraEnabled
    public String toolName;
  }

  /** @description Full display state of one session. */
  public class SessionState {
    @AuraEnabled
    public Id sessionId;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String agentDeveloperName;
    @AuraEnabled
    public String title;
    @AuraEnabled
    public String latestRunStatus;
    @AuraEnabled
    public String latestRunError;
    @AuraEnabled
    public List<ChatMessage> messages;
  }

  /** @description Sidebar row for one session. */
  public class SessionSummary {
    @AuraEnabled
    public Id sessionId;
    @AuraEnabled
    public String agentDeveloperName;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String title;
    @AuraEnabled
    public Integer turnCount;
    @AuraEnabled
    public Datetime lastActivity;
  }
}
