# Apex Agent Orchestrator (AAO)

A Salesforce-native framework for building, running, and monitoring AI agents that take actions across Salesforce and external systems - with multi-turn chat, long-term memory, and full run observability built in.

## What This Project Is

A managed-package-ready orchestration layer that provides:

- **Multi-step agent reasoning** - an async ReAct loop where each LLM/tool step runs in its own transaction, chained by platform events (no queueable depth limits)
- **Apex-based tool execution** - CRUD, query, describe, and validation tools out of the box; new tools are one class + two Custom Metadata records
- **Multi-agent collaboration** - agents delegate to sub-agents via suspend/resume, with parallel tool fan-out
- **Conversational sessions** - ChatGPT-style threads: users reply and the agent remembers the conversation, with automatic history compaction for long threads
- **Long-term memory** - agents extract durable facts and preferences from runs, recall them into future prompts, and learn lessons from their own successes and failures (pluggable store, Salesforce-native today, vector-ready)
- **LLM provider abstraction** - provider configs in Custom Metadata; OpenAI, Anthropic (Claude), and Azure OpenAI out of the box, new providers are one class + one factory branch
- **Full observability** - every run and step persisted, live progress events, a run monitor with cancel/re-run, and a step-by-step trace viewer
- **Admin-configurable agents** via Custom Metadata - prompts, tool grants, providers, and memory behavior are records, not code

## The Agent Orchestrator App

The included Lightning app ships six UI surfaces (LWCs):

| Tab              | What it does                                                                                                                                                                                         |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Agent Chat**   | Chat with any active agent: session sidebar, live "Calling QuerySalesforceTool…" progress, tool activity chips. Also embeddable on record pages (auto-attaches the record as context).               |
| **Run Monitor**  | Live, filterable table of all runs with Cancel and Re-run actions.                                                                                                                                   |
| **Agents**       | Agent builder: view or edit each agent's prompt, tools, provider, and memory config - edits deploy through the Metadata API with live status - plus a "what the LLM actually sees" manifest preview. |
| **Memories**     | What agents remember: users curate their own memories; admins curate everything, including the reflection lesson review queue.                                                                       |
| **Tool Catalog** | Every registered tool with input/output schemas, prompt guidance, and per-agent grants.                                                                                                              |
| **Test Bench**   | Run any agent against an editable input JSON (savable samples) and watch the live step trace.                                                                                                        |

Plus the **Agent Run** record page trace: step timeline with expandable LLM request/response detail and the sub-agent family tree.

## Core Components

- **AgentEngine** - the execution state machine: `runAgent` (one-shot) and `runAgentInSession` (conversational) entry points, LLM/tool steps, parallel fan-out, sub-agent suspend/resume, cancel guards.
- **ToolRegistry / AgentTool** - discovers and invokes Apex tools; access is granted per agent via `Agent_Tool_Mapping__mdt`.
- **LLMClient / LLMClientFactory** - provider-agnostic LLM interface driven by `LLM_Provider__mdt`; ships `OpenAIClient`, `AnthropicClient`, and `AzureOpenAIClient`.
- **AgentDeployService / AgentDeployCallback** - deploys agent definitions and tool grants from the builder UI via `Metadata.Operations`, reporting completion over the UI event channel.
- **MemoryProvider / MemoryService** - pluggable memory store (`Agent_Memory__c` + `SalesforceMemoryProvider` today); recall injects "Relevant memories" and "Lessons from previous runs" into prompts, `MemoryCaptureQueueable` extracts facts and reflections after runs.
- **HistoryCompactor** - summarizes long conversations before they hit the 128KB history ceiling, via a configurable cheap maintenance model.
- **ExecutionLogger** - persists every run (`Agent_Run__c`) and step (`Agent_Step__c`); the single termination choke point that releases sessions, resumes parents, and publishes UI events.
- **UIEventPublisher / Agent_UI_Event\_\_e** - live progress channel the LWCs subscribe to (with polling fallback).
- **AgentWatchdogSchedulable / MemoryJanitorSchedulable** - hourly timeout of stuck runs and orphaned sessions; nightly pruning of expired/stale memories.
- **Custom Metadata** - `Agent_Definition__mdt`, `Agent_Tool_Definition__mdt`, `Agent_Tool_Mapping__mdt`, `LLM_Provider__mdt`, `Memory_Config__mdt`.

## Permission Sets

- **AAO_Admin** - full access: all objects, all tabs, monitoring, builder, test bench.
- **AAO_User** - chat + own memories: start sessions, converse with agents, and curate what agents remember about them.

## Apex Reference Documentation

Apex classes are documented with [ApexDocs](https://github.com/cesarParra/apexdocs) via `/** @description ... */` comment blocks. The generated reference guide is a build artifact (`docs/apex/`, gitignored) - regenerate it locally whenever you want current docs:

```bash
npm install
npm run docs
```

This reads `apexdocs.config.mjs` and writes a Markdown reference guide to `docs/apex/`, grouped by architecture area (Agent Engine, Agent Tools, LLM Integration, Memory, UI, Tests). Open `docs/apex/index.md` as the entry point.

When adding or changing a public class, method, or constructor, add/update its `@description`/`@param`/`@return` ApexDoc comment so the generated docs stay accurate.

## Installation

**Current version: 1.0 Beta.** This is a managed package Beta - install into a sandbox, scratch org, or Developer Edition org for testing, not a production org (Beta versions can't be installed into production).

Install link: https://login.salesforce.com/packaging/installPackage.apexp?p0=04tbm000000Uvbx

## Post-Install Setup

### 1. Grant the Automated Process User access to LLM credentials

Agent steps are chained via a Platform Event (`Agent_Step_Event__e`) so that long-running agents aren't limited by Apex's queueable chain-depth cap. As a side effect, the Queueable that performs the LLM callout is enqueued from the event trigger and therefore executes as the **Automated Process User**, not the user who started the run.

If your LLM provider's Named/External Credential (e.g. `OpenAI_Credential`) uses per-principal access control, you'll see a run fail with:

> We couldn't access the credential(s). You might not have the required permissions, or the external credential "..." might not exist.

To fix this, after installing the package:

1. Setup → Named Credentials → External Credentials → select your LLM provider's external credential.
2. Note the permission set(s) listed under **Permission Set Mappings**.
3. The Automated Process User is a restricted system user - you cannot open its User Detail page (you'll get an "Insufficient Privileges" error if you try). Instead, assign the permission set from the **permission set's** side:
   - Setup → Permission Sets → open the permission set with the External Credential Principal Access mapping.
   - Click **Manage Assignments** → **Add Assignment**.
   - Search for and select the **Automated Process** user, then save.
   - If the Automated Process user doesn't appear in that list for some reason, it can also be assigned via anonymous Apex:
     ```apex
     User automatedProcessUser = [SELECT Id FROM User WHERE UserType = 'AutomatedProcess' LIMIT 1];
     PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'YOUR_PERMISSION_SET_NAME' LIMIT 1];
     insert new PermissionSetAssignment(AssigneeId = automatedProcessUser.Id, PermissionSetId = ps.Id);
     ```

If your external credential uses **Per-User** authentication, switch it to a **Named Principal** instead - the Automated Process User cannot complete a per-user OAuth flow.

**Named credentials per provider:** the shipped `LLM_Provider__mdt` records expect a named credential that injects the provider's auth header - `OpenAI_NC` (`Authorization: Bearer`), `Anthropic_NC` (`x-api-key`), `AzureOpenAI_NC` (`api-key`, with your deployment name and `api-version` in the record's endpoint path). Create the credential(s) for the providers you use and grant the Automated Process User access as above.

### 2. Grant Metadata API access for the Agent Builder

The builder's **Save** action (`AgentDeployService`) deploys `Agent_Definition__mdt`/`Agent_Tool_Mapping__mdt` records through the Apex Metadata API (`Metadata.Operations.enqueueDeployment`). Every subscriber org needs to satisfy two *independent* requirements, or the builder fails with:

> Not allowed to install or modify metadata via Apex

**a. User permissions.** The running user needs **Customize Application** and **Modify Metadata Through Metadata API Functions**. Salesforce does not allow a managed package to grant these via a packaged permission set, so `AAO_Admin` intentionally ships without them - grant them manually:

1. Setup → Profiles (not Permission Sets - Salesforce has a known issue where **Modify Metadata Through Metadata API Functions** granted via a permission set doesn't actually take effect) → open the builder user's profile → System Permissions.
2. Enable **Customize Application** and **Modify Metadata Through Metadata API Functions**, then save.

**b. Org-wide Apex Setting for non-certified packages.** While this package is Beta and not AppExchange security-reviewed, the org must separately opt in to letting *any* code from it call the Metadata API:

1. Setup → Quick Find → **Apex Settings**.
2. Enable **Deploy Metadata from Non-Certified Package Version via Apex**, then save.

Both (a) and (b) are required - having only the user permissions still throws the same error until the Apex Setting is enabled too.

Note that `Agent_Definition__mdt` and its sibling types don't show up under Setup → Custom Metadata Types for subscribers at all, independent of the above - every record this package ships is marked `protected`, which is namespace-scoped by design. The Agent Builder is the only supported way to manage them; that's not a permission gap to fix.

### 3. Schedule the background jobs

Two scheduled jobs keep runs and memories healthy: the **watchdog** (hourly - times out runs stuck `Running`, resumes suspended parents, releases stuck sessions) and the **memory janitor** (nightly - deactivates expired and stale memories). Schedule both with:

```bash
sf apex run --file scripts/apex/ScheduleWatchdog.apex --target-org <alias>
```

> **Deploy note:** scheduled Apex blocks class deployments. Either run `scripts/apex/UnscheduleWatchdog.apex` before deploying (and re-run the schedule script after), or enable _Allow deployments with active Apex jobs_ under Setup → Deployment Settings.

### 4. Assign permission sets

Assign **AAO_Admin** to builders/admins and **AAO_User** to anyone who should chat with agents, then open the **Agent Orchestrator** app from the App Launcher.

### 5. Configure memory (optional)

Each agent's `Agent_Definition__mdt.MemoryConfig__c` points at a `Memory_Config__mdt` record:

- **NoMemory** - recall and capture disabled.
- **Default_Memory** - fact extraction + reflection on, compaction at 90k chars, recall of up to 10 memories per run.

To cut token costs, set `Maintenance_Provider__c` on the config to a cheap model's `LLM_Provider__mdt` record - compaction, extraction, and reflection calls route there instead of the agent's main model.

### 6. Using agents from Flow (optional)

Three invocable actions are available in Flow Builder under the **Apex Agent Orchestrator** category:

- **Apex Agent: Run Agent** - starts a one-shot run (no conversation session).
- **Apex Agent: Send Chat Message** - starts or continues a conversation (pass a blank Session Id to start a new one).
- **Apex Agent: Get Run Result** - checks a run's status.

Both `Run Agent` and `Send Chat Message` return immediately with a Run Id - the agent loop finishes asynchronously via platform events. Poll with a Wait element that loops **Get Run Result** until `Is Done` is true, then read `Final Message` (or `Error Message` on failure).

## Roadmap

- ✅ Agent execution loop (async, event-chained)
- ✅ Tool interface + registry
- ✅ LLM provider abstraction
- ✅ Error-aware retries, parallel tools, multi-agent delegation
- ✅ Execution logs + run monitor with cancel/re-run
- ✅ Conversational sessions + chat UI
- ✅ Memory: compaction, long-term store, reflection
- ✅ Builder viewer, tool catalog, test bench
- ✅ Additional LLM providers (Anthropic Claude, Azure OpenAI)
- ✅ Agent authoring from the builder (Metadata API deploys)
- ✅ Memory management UI
- ⏳ Vector/hybrid memory recall (provider seam in place)
- ⏳ Managed package release
