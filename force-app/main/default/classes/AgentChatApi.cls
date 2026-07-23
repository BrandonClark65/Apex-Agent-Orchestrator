/**
 * @description External REST boundary for driving an agent conversation from outside Salesforce
 * (e.g. a customer-facing web chatbot). It is the HTTP mirror of the `aaoAgentChat` LWC's
 * controller: start/continue a session and poll its state.
 *
 * Single-agent, customer-facing model: the chat is bound to exactly ONE agent, chosen by whoever
 * sets up the chat by flagging that `Agent_Definition__mdt.Externally_Accessible__c = true` (and
 * only that one). The end user never picks an agent — the agent is resolved server-side and any
 * agent name a client sends is ignored. What the customer sees is also trimmed to their own
 * messages and the agent's final answers: the tool calls and intermediate "thinking" are hidden
 * (see `ChatMessageRenderer.render(history, false)`).
 *
 * Identity model (integration user): every call authenticates as one Salesforce integration user
 * via a Connected App; the end user is identified by the opaque `externalRef` the caller passes.
 * Sessions are stamped with `External_Ref__c`, and every read/continue is scoped to a matching
 * `externalRef`, so one external caller can never see or continue another's thread.
 *
 * Because runs are asynchronous, `POST` returns a `runId`/`sessionId` immediately and the caller
 * polls `GET /agent/session/{id}` until `latestRunStatus` leaves `Running`.
 *
 * Routes (under `/services/apexrest/agent`):
 *   POST /agent/message            body {message, externalRef, sessionId?}
 *   GET  /agent/session/{id}?externalRef=...
 *   GET  /agent/config
 * @group External API
 */
@RestResource(urlMapping='/agent/*')
global with sharing class AgentChatApi {
  private static final Integer MAX_MESSAGE_LENGTH = 8000;

  // Per-externalRef rate limit on POST /message — each call starts a billed LLM run, so this
  // caps how many turns one external caller can drive per window. Tunable statics for this POC
  // (a production package would likely source these from config); set rateLimitMaxRequests to 0
  // to disable. @TestVisible so tests can dial them down.
  @TestVisible
  private static Integer rateLimitMaxRequests = 20;
  @TestVisible
  private static Integer rateLimitWindowSeconds = 60;

  // Test seam: when set, stands in for the configured external agent (CMDT records can't be
  // inserted or flagged in tests). Never populated outside of test context.
  @TestVisible
  private static String externalAgentOverride;

  // ───────────────────────────────────────────────────────────────
  // POST /agent/message — start or continue a conversation
  // ───────────────────────────────────────────────────────────────
  @HttpPost
  global static void doPost() {
    try {
      Map<String, Object> body = parseBody();
      String message = str(body.get('message'));
      String externalRef = str(body.get('externalRef'));
      String sessionIdRaw = str(body.get('sessionId'));
      // Authenticated customer number, bound to a NEW session so record-scoped tools
      // (GetMyCases, GetMyAccount) filter to this customer only. The trusted backend proxy
      // must set this from the logged-in customer — never from anything the browser user
      // types. It is deliberately ignored when continuing an existing session, which keeps
      // the customer number stamped at creation, so a caller cannot re-scope a live thread.
      String customerNumber = str(body.get('customerNumber'));

      if (String.isBlank(externalRef)) {
        respond(400, new Map<String, Object>{ 'error' => 'externalRef is required' });
        return;
      }
      if (String.isBlank(message)) {
        respond(400, new Map<String, Object>{ 'error' => 'message is required' });
        return;
      }
      if (message.length() > MAX_MESSAGE_LENGTH) {
        respond(
          400,
          new Map<String, Object>{
            'error' => 'message exceeds ' + MAX_MESSAGE_LENGTH + ' characters'
          }
        );
        return;
      }

      // Rate-limit before doing any work — applies to both new and continued threads, since
      // either starts a billed run.
      if (isRateLimited(externalRef)) {
        RestContext.response.addHeader(
          'Retry-After',
          String.valueOf(rateLimitWindowSeconds)
        );
        respond(
          429,
          new Map<String, Object>{
            'error' => 'Too many messages. Please wait a moment and try again.'
          }
        );
        return;
      }

      Id sessionId = String.isBlank(sessionIdRaw) ? null : (Id) sessionIdRaw;

      // The agent is fixed server-side for new threads; continuing uses the session's own agent.
      String agent = null;
      if (sessionId == null) {
        String configError;
        try {
          agent = resolveExternalAgent();
        } catch (ConfigException ce) {
          configError = ce.getMessage();
        }
        if (configError != null) {
          respond(503, new Map<String, Object>{ 'error' => configError });
          return;
        }
        if (agent == null) {
          respond(
            503,
            new Map<String, Object>{ 'error' => 'External chat is not configured.' }
          );
          return;
        }
      } else {
        // Continuing: the session must belong to this external caller.
        List<Agent_Session__c> existing = [
          SELECT External_Ref__c
          FROM Agent_Session__c
          WHERE Id = :sessionId
          LIMIT 1
        ];
        if (existing.isEmpty() || existing[0].External_Ref__c != externalRef) {
          respond(403, new Map<String, Object>{ 'error' => 'Session not found for this caller' });
          return;
        }
      }

      Id runId = AgentEngine.runAgentInSession(
        agent,
        message,
        sessionId,
        'API'
      );
      Id resolvedSessionId = [
        SELECT Session__c
        FROM aao__Agent_Run__c
        WHERE Id = :runId
        LIMIT 1
      ]
      .Session__c;

      // Stamp the external identity (and, when supplied, the customer scope) onto a newly
      // created session. Both come from the trusted API boundary, not the conversation.
      if (sessionId == null) {
        update new Agent_Session__c(
          Id = resolvedSessionId,
          External_Ref__c = externalRef,
          Customer_Number__c = String.isBlank(customerNumber) ? null : customerNumber
        );
      }

      respond(
        202,
        new Map<String, Object>{
          'sessionId' => resolvedSessionId,
          'runId' => runId,
          'status' => 'Running'
        }
      );
    } catch (Exception e) {
      respond(500, new Map<String, Object>{ 'error' => e.getMessage() });
    }
  }

  // ───────────────────────────────────────────────────────────────
  // GET /agent/session/{id}  and  GET /agent/config
  // ───────────────────────────────────────────────────────────────
  @HttpGet
  global static void doGet() {
    try {
      List<String> segs = pathSegments();
      String resource = segs.isEmpty() ? '' : segs[0];

      if (resource == 'config') {
        getConfig();
        return;
      }

      if (resource == 'session') {
        if (segs.size() < 2) {
          respond(400, new Map<String, Object>{ 'error' => 'session id is required' });
          return;
        }
        getSession(segs[1]);
        return;
      }

      respond(404, new Map<String, Object>{ 'error' => 'Unknown resource: ' + resource });
    } catch (Exception e) {
      respond(500, new Map<String, Object>{ 'error' => e.getMessage() });
    }
  }

  // Public display info for the one configured agent, so a client can label the chat without
  // ever offering a choice. Never exposes the agent's internal goal/prompt.
  private static void getConfig() {
    String agent;
    try {
      agent = resolveExternalAgent();
    } catch (ConfigException ce) {
      respond(503, new Map<String, Object>{ 'error' => ce.getMessage() });
      return;
    }
    if (agent == null) {
      respond(503, new Map<String, Object>{ 'error' => 'External chat is not configured.' });
      return;
    }
    List<aao__Agent_Definition__mdt> defs = [
      SELECT MasterLabel
      FROM aao__Agent_Definition__mdt
      WHERE DeveloperName = :agent
      LIMIT 1
    ];
    respond(
      200,
      new Map<String, Object>{
        'agentLabel' => defs.isEmpty() ? 'Assistant' : defs[0].MasterLabel
      }
    );
  }

  private static void getSession(String sessionIdRaw) {
    String externalRef = RestContext.request.params.get('externalRef');
    if (String.isBlank(externalRef)) {
      respond(400, new Map<String, Object>{ 'error' => 'externalRef is required' });
      return;
    }

    Id sessionId;
    try {
      sessionId = (Id) sessionIdRaw;
    } catch (Exception e) {
      respond(400, new Map<String, Object>{ 'error' => 'Invalid session id' });
      return;
    }

    List<Agent_Session__c> sessions = [
      SELECT Status__c, Title__c, External_Ref__c
      FROM Agent_Session__c
      WHERE Id = :sessionId
      LIMIT 1
    ];
    if (sessions.isEmpty() || sessions[0].External_Ref__c != externalRef) {
      respond(404, new Map<String, Object>{ 'error' => 'Session not found for this caller' });
      return;
    }
    Agent_Session__c session = sessions[0];

    Map<String, Object> state = new Map<String, Object>{
      'sessionId' => sessionId,
      'status' => session.Status__c,
      'title' => session.Title__c,
      // Customer-facing: hide tool activity and intermediate thinking.
      'messages' => ChatMessageRenderer.render(
        SessionService.loadSeedHistory(sessionId),
        false
      )
    };

    // latestRunStatus lets the client stop polling; the error detail is deliberately not
    // surfaced to an external customer — a client shows a friendly failure message instead.
    List<aao__Agent_Run__c> latestRuns = [
      SELECT aao__Status__c
      FROM aao__Agent_Run__c
      WHERE Session__c = :sessionId
      ORDER BY Turn_Number__c DESC
      LIMIT 1
    ];
    if (!latestRuns.isEmpty()) {
      state.put('latestRunStatus', latestRuns[0].aao__Status__c);
    }

    respond(200, state);
  }

  // ───────────────────────────────────────────────────────────────
  // Helpers
  // ───────────────────────────────────────────────────────────────

  // The single agent exposed to external chat: the one flagged Externally_Accessible + Active.
  // Returns null when none is configured; throws when more than one is flagged, since the
  // customer-facing chat is intentionally bound to exactly one agent.
  private static String resolveExternalAgent() {
    if (externalAgentOverride != null) {
      return externalAgentOverride;
    }
    List<aao__Agent_Definition__mdt> defs = [
      SELECT DeveloperName
      FROM aao__Agent_Definition__mdt
      WHERE aao__IsActive__c = TRUE AND aao__Externally_Accessible__c = TRUE
      ORDER BY DeveloperName
      LIMIT 2
    ];
    if (defs.isEmpty()) {
      return null;
    }
    if (defs.size() > 1) {
      throw new ConfigException(
        'External chat is misconfigured: exactly one agent may be marked Externally Accessible.'
      );
    }
    return defs[0].DeveloperName;
  }

  private class ConfigException extends Exception {
  }

  // A run is created per POST /message, so counting the caller's recent runs across all their
  // threads bounds billed LLM turns per externalRef per window. External_Ref__c is indexed.
  private static Boolean isRateLimited(String externalRef) {
    if (rateLimitMaxRequests <= 0) {
      return false;
    }
    DateTime cutoff = System.now().addSeconds(-rateLimitWindowSeconds);
    Integer recent = [
      SELECT COUNT()
      FROM aao__Agent_Run__c
      WHERE Session__r.External_Ref__c = :externalRef AND CreatedDate >= :cutoff
    ];
    return recent >= rateLimitMaxRequests;
  }

  // Path segments after the '/agent' resource root, e.g. '/agent/session/123' -> ['session','123'].
  private static List<String> pathSegments() {
    String uri = RestContext.request.requestURI;
    Integer idx = uri.indexOf('/agent');
    String tail = idx >= 0 ? uri.substring(idx + '/agent'.length()) : '';
    List<String> segs = new List<String>();
    for (String s : tail.split('/')) {
      if (String.isNotBlank(s)) {
        segs.add(s);
      }
    }
    return segs;
  }

  private static Map<String, Object> parseBody() {
    Blob b = RestContext.request.requestBody;
    if (b == null || String.isBlank(b.toString())) {
      return new Map<String, Object>();
    }
    Object parsed = JSON.deserializeUntyped(b.toString());
    return parsed instanceof Map<String, Object>
      ? (Map<String, Object>) parsed
      : new Map<String, Object>();
  }

  private static String str(Object o) {
    return o == null ? null : String.valueOf(o);
  }

  private static void respond(Integer statusCode, Map<String, Object> body) {
    RestResponse res = RestContext.response;
    res.statusCode = statusCode;
    res.addHeader('Content-Type', 'application/json');
    res.responseBody = Blob.valueOf(JSON.serialize(body));
  }
}
