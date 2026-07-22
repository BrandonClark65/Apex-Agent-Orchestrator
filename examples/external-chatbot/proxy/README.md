# External chatbot proxy

A tiny, dependency-free Node proxy that sits between the [widget](../index.html) and Salesforce.
It exists to solve the two problems you hit running the widget straight against Salesforce:

- **No token in the browser.** The proxy mints and caches the integration-user OAuth access token
  server-side (Client Credentials flow) and adds `Authorization: Bearer …` to each forwarded call.
  The customer's browser never sees the token.
- **No CORS.** The proxy serves the widget *and* the API from the same origin, so the browser makes
  no cross-origin request — there is nothing to allowlist under Setup → CORS.

```
browser ──▶ proxy (same origin)  ──Bearer token──▶  /services/apexrest/agent/*  (Salesforce)
  widget      holds + refreshes token
```

## Prerequisites

- **Node 18+** (uses the built-in global `fetch`; no npm dependencies).
- A **Connected App** with **Client Credentials Flow** enabled and its **Run-As** user set to your
  integration user (Setup → App Manager → your app → Manage → Edit Policies). Scope must include
  `Manage user data via APIs (api)`.
- Exactly one active `Agent_Definition__mdt` flagged `Externally_Accessible__c = true` — that is the
  agent the chat uses (the widget never chooses it).

## Run it

```bash
cd examples/external-chatbot/proxy
cp .env.example .env         # fill in SF_LOGIN_URL, SF_CLIENT_ID, SF_CLIENT_SECRET
export $(grep -v '^#' .env | xargs)   # load .env into the environment (bash)
npm start
```

Then open **http://localhost:8080**, click ⚙, and set:

| Field | Value |
| --- | --- |
| **API base URL** | `/agent` |
| **Bearer token** | *(leave blank — the proxy holds it)* |
| **External ref** | *(leave blank to auto-generate)* |

That's it — the widget is now live with no token in the browser and no CORS.

## What it forwards

| Widget call | Proxied to Salesforce |
| --- | --- |
| `GET /agent/config` | `GET /services/apexrest/agent/config` |
| `POST /agent/message` | `POST /services/apexrest/agent/message` |
| `GET /agent/session/{id}?externalRef=…` | `GET /services/apexrest/agent/session/{id}?externalRef=…` |

The token is cached in memory and refreshed automatically; a `401` from Salesforce forces a one-time
re-mint. Nothing about the agent or the token is exposed to the client — the proxy is a pass-through
for exactly these three routes and otherwise just serves the widget's static files.

## Troubleshooting a 502

A `502` in the browser means the proxy reached Salesforce but that call failed — the browser only
gets a generic message on purpose. The real reason is logged in the terminal running `npm start` as
a `[proxy] …` line. To also echo it to the browser while debugging, start with `DEBUG=1`:

```bash
DEBUG=1 npm start
```

Common causes:

| `[proxy]` detail | Fix |
| --- | --- |
| `OAuth token request failed: unsupported_grant_type` | Enable **Client Credentials Flow** on the Connected App and set its **Run-As** user (Manage → Edit Policies). Changes take a few minutes to propagate. |
| `OAuth token request failed: invalid_client` / `invalid_client_id` | Wrong `SF_CLIENT_ID` / `SF_CLIENT_SECRET`. |
| `fetch failed (getaddrinfo ENOTFOUND …)` | `SF_LOGIN_URL` is wrong or still a placeholder — use your real `*.my.salesforce.com` host. |
| `OAuth token request failed: …` but creds look right | Env vars not loaded into the process — re-run the `export $(…)` line, or confirm with `echo $SF_CLIENT_ID`. |

If the OAuth call succeeds but Salesforce returns `{"errorCode":"NOT_FOUND","message":"Could not
find a match for URL …"}`, the Apex REST path is wrong for how AAO is deployed. AAO installed as a
**managed package** exposes a **namespaced** endpoint — set `SF_APEXREST_PATH=/services/apexrest/aao/agent`.
An unmanaged source deploy uses the default `/services/apexrest/agent`. The startup log prints the
path it's forwarding to.

## Production notes

This is still a starting point, not a hardened gateway. Before going public you'd typically add: TLS
(run it behind a real web server / load balancer), the widget's origin locked down, request logging,
and the Connected App's integration user scoped to the **least** access its one agent needs. Keep
`.env` out of source control (it already is via `.gitignore`).
