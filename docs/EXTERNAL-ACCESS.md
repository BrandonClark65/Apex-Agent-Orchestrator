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
| `POST` | `/agent/message` | `{message, externalRef, sessionId?}` | Start (no `sessionId`) or continue a conversation. The agent is resolved server-side. Returns `{sessionId, runId, status}` (HTTP 202). Rate-limited per `externalRef` → `429` with `Retry-After` when exceeded. |
| `GET` | `/agent/session/{id}` | `?externalRef=...` | Poll a thread: `{status, title, latestRunStatus, messages[]}`. `messages[]` excludes tool activity. |
| `GET` | `/agent/config` | — | Display info for the one configured agent: `{agentLabel}`. Lets a client title the chat without ever offering a choice. |

`messages[]` entries are `{role, text}` where `role` is `user` or `assistant`. An assistant entry
may also carry `data` — the structured half of the agent's final answer (every key of the `final`
object other than `message`, which becomes `text`). It's present only when the final answer included
extra keys, letting a client render cards/links/buttons while the bubble stays plain prose.

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
