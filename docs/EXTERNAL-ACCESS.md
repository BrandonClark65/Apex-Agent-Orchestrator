# External Access (REST API + Web Chatbot)

This explores driving an AAO agent from **outside Salesforce** — a customer-facing web chatbot
bound to a single agent. It is a proof-of-concept slice: the REST boundary, the identity model,
the safety gates, and a standalone widget.

## Architecture

Everything the chat LWC does is `@AuraEnabled` — reachable only from a Salesforce Lightning
session. `AgentChatApi` (`@RestResource`) is the HTTP mirror of that controller, reusing the same
engine and the same message projection (`ChatMessageRenderer`).

```
web chatbot ──HTTPS──▶ /services/apexrest/agent/*  (AgentChatApi)
                              │  POST /message  ──▶ AgentEngine.runAgentInSession (async)
                              │  GET  /session/{id}  ◀── poll until latestRunStatus != Running
                              └─ ChatMessageRenderer.render(history, false)  (tools hidden)
```

Runs are asynchronous (event-hopped), so no endpoint returns the answer synchronously: `POST`
returns a `runId`/`sessionId` immediately and the client **polls** `GET /session/{id}` — exactly
how the LWC's fallback and the Flow loop already work. (A future upgrade could stream
`Agent_UI_Event__e` over the Pub/Sub API instead of polling.)

## Customer-facing model

**One agent, chosen by the setup, never by the customer.** The chat is bound to exactly one
agent: whoever sets up the chat flags that `Agent_Definition__mdt.Externally_Accessible__c = true`
(and only that one). The API resolves the agent **server-side** and ignores any agent name a
client sends, so the end user can neither see nor choose an agent. If zero agents are flagged the
API returns `503` (not configured); if more than one is flagged it returns `503` (misconfigured) —
the single-agent invariant is enforced, not guessed.

**Friendly answers only.** The customer sees their own messages and the agent's final answers.
Tool calls, tool outputs, and intermediate "thinking" are stripped from the external transcript
(`ChatMessageRenderer.render(history, false)`), and run error detail is not returned — a client
shows a generic "please try again" instead. The in-org LWC still shows the full tool activity.

## Identity model: integration user + `External_Ref__c`

Every call authenticates as **one** Salesforce integration user via a Connected App; the end user
is identified by an opaque `externalRef` the caller supplies. New sessions are stamped with
`Agent_Session__c.External_Ref__c`, and every read/continue is scoped to a matching `externalRef`,
so one external caller can never see or continue another's thread even though they share a
Salesforce user.

## Endpoints

| Method | Path | Body / Query | Purpose |
| --- | --- | --- | --- |
| `POST` | `/agent/message` | `{message, externalRef, sessionId?, customerNumber?}` | Start (no `sessionId`) or continue a conversation. The agent is resolved server-side. `customerNumber` is bound to a **new** session for record scoping (see below) and ignored when continuing. Returns `{sessionId, runId, status}` (HTTP 202). Rate-limited per `externalRef` → `429` with `Retry-After` when exceeded. |
| `GET` | `/agent/session/{id}` | `?externalRef=...` | Poll a thread: `{status, title, latestRunStatus, messages[]}`. `messages[]` excludes tool activity. |
| `GET` | `/agent/config` | — | Display info for the one configured agent: `{agentLabel}`. Lets a client title the chat without ever offering a choice. |

`messages[]` entries are `{role, text}` where `role` is `user` or `assistant`. An assistant entry
may also carry `data` — the structured half of the agent's final answer (every key of the `final`
object other than `message`, which becomes `text`). It's present only when the final answer included
extra keys, letting a client render cards/links/buttons while the bubble stays plain prose.

## Record-level scoping (only this customer's records)

`External_Ref__c` isolates **conversation threads** — one caller can't see another's chat. It does
**not** by itself isolate **records**: every external call runs as the *same* integration user, so
user-mode permissions are identical for every customer. Those are two different jobs, and a
customer-facing chat that answers "what are my open cases?" needs both.

The second layer is a bound customer identity plus purpose-built tools:

- **Bind the customer server-side, never from the chat.** A new session is stamped with
  `Agent_Session__c.Customer_Number__c` from the `customerNumber` on `POST /message`. The trusted
  backend proxy sets that from the *logged-in* customer on your site — never from anything the
  browser user types. It's ignored when continuing a session, so a caller can't re-scope a live
  thread. `AgentEngine.runToolStep` copies it into `AgentToolContext.customerNumber` before each
  tool runs.
- **Don't grant the external agent the raw `QuerySalesforceTool`.** Arbitrary LLM-authored SOQL
  lets a customer ask for anything the integration user can see. Give this one agent a small set of
  pre-scoped tools instead.
- **Scoped tools inject the filter, take no customer argument.** `GetMyCasesTool` and
  `GetMyAccountTool` read the bound customer number from `AgentToolContext`, hard-filter on it with
  a bind variable (`WHERE Account.AccountNumber = :customerNumber`), run `WITH USER_MODE`, and fail
  closed if no customer is bound. Their input schema is empty — there is no customer identifier for
  the model (or the user) to spoof. Map "customer number" to whatever your schema uses (a custom
  field, external Id, etc.) by editing the query in those classes.

> **The system prompt is not the boundary.** "Only discuss this customer's data" in the agent
> prompt is good UX but must never be your only control — each scoped tool's `WHERE` clause is the
> real boundary. Keep the integration user least-privileged so even a prompt trick can't reach
> objects the tools don't expose.

## Safety gates

- **Single, opt-in agent.** `Externally_Accessible__c` defaults to `false`, so nothing is exposed
  until an admin opts exactly one agent in. Do not flag internal/privileged agents.
- **No client-chosen agent / no tool exposure.** Enforced server-side, as above.
- **Message size.** Messages over 8,000 characters are rejected (`400`).
- **User-mode data access.** Tool reads/writes run in user mode, so the integration user's
  object/field/record permissions bound what any external conversation can touch. Give that user
  the **least** access its agent needs.
- **Rate limiting.** `POST /message` is capped per `externalRef` — each call starts a billed run,
  so one caller can drive at most `rateLimitMaxRequests` turns per `rateLimitWindowSeconds`
  (default 20/60s). Over the cap returns `429` with a `Retry-After` header. The count reuses the
  caller's recent `Agent_Run__c` rows (no extra storage); the limits are tunable statics today and
  a natural candidate to move to config.

## Setup (live org)

1. **Integration user** — a dedicated user with a permission set granting: Apex class access to
   `AgentChatApi`, and only the objects/fields its one agent needs.
2. **Connected App** — OAuth enabled. For a server-to-server bot, use the **JWT bearer** or
   **client-credentials** flow bound to the integration user. The backend exchanges that for an
   access token and sends it as `Authorization: Bearer <token>`.
3. **Choose the agent** — set `Externally_Accessible__c = true` on exactly one active
   `Agent_Definition__mdt`.
4. **Call it** — `POST https://<instance>.my.salesforce.com/services/apexrest/agent/message`.

> **Don't put the integration token in the customer's browser.** For a public site, front the API
> with a thin backend proxy that holds the token and forwards `message`/`session` calls — the
> browser talks to your proxy, the proxy talks to Salesforce. The direct-from-browser mode in the
> example widget is for trials and internal demos, not public production.

## Example widget

`examples/external-chatbot/index.html` is a standalone, dependency-free chat UI. Open it in a
browser: it starts in **demo mode** (canned responses, no network). Open ⚙ Settings and add the
API base URL + a bearer token to talk to a live org. It shows only the customer's messages and the
agent's answers with a typing indicator — no agent picker, no tool chips — and polls
`GET /session/{id}` until the run finishes.

> Hosting the widget on another domain requires CORS — add that origin under **Setup → CORS** in
> the target org.
