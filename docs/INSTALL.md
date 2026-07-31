# Installation and post-install setup

**Current version: 1.3.0 (Released).** This is a promoted managed package version - it can be
installed into any org, including production. Testing in a sandbox or scratch org first is
still recommended.

- [Install in production](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000P2ppAAC)
- [Install in a sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000P2ppAAC)

Steps 1-4 are required. Steps 5-8 are optional.

> **Upgrading from 1.2.0 or earlier?** 1.3.0 changes the packaged agent prompts so agents
> answer in prose instead of dumping JSON into the chat. That reaches an agent only if it has
> no `Agent_Prompt_Version__c` records - the packaged prompt is just the baseline. **An agent
> that already has prompt versions keeps running its active one and will look unchanged after
> the upgrade.** To pick up the fix there, open the Agent Builder, save a new version whose
> final-answer instruction requires `message`, and activate it. See
> [the final-answer contract](ARCHITECTURE.md#the-final-answer-contract).

---

## 1. Grant the Automated Process User access to LLM credentials

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

**Named credentials per provider:** the shipped `LLM_Provider__mdt` records expect a named credential that injects the provider's auth header - `OpenAI_NC` (`Authorization: Bearer`), `Anthropic_NC` (`x-api-key`), `AzureOpenAI_NC` (`api-key`; set `Model_Name__c` to **your Azure deployment name** - deployment names are per-resource, so the shipped `gpt-4o-mini` only works if you named your deployment that - and put the same name plus `api-version` in the record's endpoint path when using the legacy `/openai/deployments/...` style, or use the v1 path `/openai/v1/chat/completions`, which reads the deployment from `Model_Name__c`). The `Azure_OpenAI_Responses` record targets the same resource's **Responses API** (`/openai/responses?api-version=...`) through the same `AzureOpenAI_NC` credential; the `Responses` provider type also works against OpenAI directly (endpoint `/v1/responses` with a Bearer-auth credential). Create the credential(s) for the providers you use and grant the Automated Process User access as above.

## 2. Grant Metadata API access for the Agent Builder

The builder's **Save** action (`AgentDeployService`) deploys `Agent_Definition__mdt`/`Agent_Tool_Mapping__mdt` records through the Apex Metadata API (`Metadata.Operations.enqueueDeployment`). Every subscriber org needs to satisfy two _independent_ requirements, or the builder fails with:

> Not allowed to install or modify metadata via Apex

**a. User permissions.** The running user needs **Customize Application** and **Modify Metadata Through Metadata API Functions**. Salesforce does not allow a managed package to grant these via a packaged permission set, so `AAO_Admin` intentionally ships without them - grant them manually:

1. Setup → Profiles (not Permission Sets - Salesforce has a known issue where **Modify Metadata Through Metadata API Functions** granted via a permission set doesn't actually take effect) → open the builder user's profile → System Permissions.
2. Enable **Customize Application** and **Modify Metadata Through Metadata API Functions**, then save.

**b. Org-wide Apex Setting for non-certified packages.** While this package is not AppExchange security-reviewed, the org must separately opt in to letting _any_ code from it call the Metadata API:

1. Setup → Quick Find → **Apex Settings**.
2. Enable **Deploy Metadata from Non-Certified Package Version via Apex**, then save.

Both (a) and (b) are required - having only the user permissions still throws the same error until the Apex Setting is enabled too.

All five custom metadata types (`Agent_Definition__mdt`, `Agent_Tool_Definition__mdt`, `Agent_Tool_Mapping__mdt`, `LLM_Provider__mdt`, `Memory_Config__mdt`) ship with `visibility` set to **Public**, so once your org is on a package version that includes it, admins with the permissions above can view and manage records for them directly under Setup → Custom Metadata Types - not just through the Agent Builder / Tool Catalog UI. Object and field _definitions_ stay locked to the package either way; only records are editable.

The shipped example records (e.g. `LLM_Provider.OpenAI_GPT4`, `Agent_Definition.Orchestrator_Agent`) are `protected = false`, so subscribers can see and edit them, not just records they create themselves. Every field on those types is `fieldManageability = SubscriberControlled` **except** `Agent_Tool_Definition__mdt.Tool_Class__c`, `InputSchema__c`, and `OutputSchema__c`, which stay `DeveloperControlled` - those three are tied 1:1 to a registered Apex tool class and its contract, and editing them without a matching code change breaks tool execution. `SubscriberControlled` is the specific setting that makes edits upgrade-safe: once a subscriber has customized a value, future package upgrades won't overwrite it. `DeveloperControlled` is the opposite - the package can freely change that value in later versions, but subscribers can never edit it.

Visibility, `protected`, and `fieldManageability` are all packaged metadata, not subscriber-side settings - if you're upgrading from an earlier package version where these weren't set this way, the org needs to install the new version before the change takes effect.

## 3. Schedule the background jobs

Two scheduled jobs keep runs and memories healthy: the **watchdog** (hourly - times out runs stuck `Running`, resumes suspended parents, releases stuck sessions) and the **memory janitor** (nightly - deactivates expired and stale memories). Schedule both with:

```bash
sf apex run --file scripts/apex/ScheduleWatchdog.apex --target-org <alias>
```

> **Deploy note:** scheduled Apex blocks class deployments. Either run `scripts/apex/UnscheduleWatchdog.apex` before deploying (and re-run the schedule script after), or enable _Allow deployments with active Apex jobs_ under Setup → Deployment Settings.

## 4. Assign permission sets

Assign **AAO_Admin** to builders/admins and **AAO_User** to anyone who should chat with agents, then open the **Agent Orchestrator** app from the App Launcher.

Note that **AAO_User** grants read access to `Agent_Prompt_Version__c`. Chat users never edit prompts, but the Agent Builder's version panel and the run trace's version badge both read these records, so removing that access leaves those surfaces blank for them.

**What a working install looks like.** Send an agent a message, then open **Run Monitor**. You
should see the run land with a status of `Succeeded`:

![Run Monitor listing agent runs with status, trigger, depth, and start time](images/run-monitor.png)

If runs sit at `Running` and never finish, the watchdog isn't scheduled (step 3). If they go
straight to `Failed`, open the run and read the step trace - a failure on step 1 is almost
always the credential problem in step 1 above.

## 5. Seed prompt version history (optional)

Agents installed with the package start with no `Agent_Prompt_Version__c` records and run on their packaged baseline prompt. That works fine, but prompt history then begins at your first edit rather than at what shipped. To capture the shipped prompts as v1 so you can diff and roll back to them:

```bash
sf apex run --file scripts/apex/BackfillPromptVersions.apex --target-org <alias>
```

Idempotent - it skips agents that already have versions, and agents whose baseline prompt is blank. Safe to re-run after adding agents.

The script is a thin wrapper over `aao.PromptVersionBackfill.run()`, which is where the work actually happens - the version-key format and the `Active_Key__c`/`Is_Active__c` lockstep are package invariants, so they live in the package rather than in a script you'd paste into a subscriber org and forget to update. Requires package **1.2.0 or later**; on earlier versions the entry point isn't there and anonymous Apex fails with `Variable does not exist: PromptVersionBackfill`.

## 6. Configure memory (optional)

Each agent's `Agent_Definition__mdt.MemoryConfig__c` points at a `Memory_Config__mdt` record:

- **NoMemory** - recall and capture disabled.
- **Default_Memory** - fact extraction + reflection on, compaction at 90k chars, recall of up to 10 memories per run.

To cut token costs, set `Maintenance_Provider__c` on the config to a cheap model's `LLM_Provider__mdt` record - compaction, extraction, and reflection calls route there instead of the agent's main model.

## 7. Using agents from Flow (optional)

Three invocable actions are available in Flow Builder under the **Apex Agent Orchestrator** category:

- **Apex Agent: Run Agent** - starts a one-shot run (no conversation session).
- **Apex Agent: Send Chat Message** - starts or continues a conversation (pass a blank Session Id to start a new one).
- **Apex Agent: Get Run Result** - checks a run's status.

Both `Run Agent` and `Send Chat Message` return immediately with a Run Id - the agent loop finishes asynchronously via platform events. Poll with a Wait element that loops **Get Run Result** until `Is Done` is true, then read `Final Message` (or `Error Message` on failure).

## 8. External chat access (optional)

`AgentChatApi` exposes one agent to non-Salesforce clients (e.g. a website chat widget) over REST at `/services/apexrest/agent/*`. It's the HTTP mirror of the in-org chat, bound to a single agent and trimmed for customer-facing use. The full walkthrough - auth, endpoints, and the example widget - is in [EXTERNAL-ACCESS.md](EXTERNAL-ACCESS.md); the essentials:

- **Pick the agent.** Set `Externally_Accessible__c = true` on exactly one active `Agent_Definition__mdt`. The end user never chooses an agent - the API resolves it server-side and ignores any agent a client sends (zero flagged → `503` not configured; more than one → `503` misconfigured).
- **Authenticate.** Calls run as one integration user via a Connected App (JWT bearer or client-credentials flow). Give that user least-privilege access - user-mode tools bound what any conversation can touch.
- **Endpoints.** `POST /agent/message` `{message, externalRef, sessionId?}` starts or continues a thread and returns immediately (poll for the answer); `GET /agent/session/{id}?externalRef=…` polls a thread; `GET /agent/config` returns the agent's display label.
- **Customer-safe by default.** Session responses show only the user's messages and the agent's final answers - tool calls, intermediate thinking, and error internals are stripped. `POST` is rate-limited per `externalRef` (default 20 turns / 60s → `429` with `Retry-After`).
- **Example widget.** `examples/external-chatbot/index.html` is a standalone chat UI (demo mode out of the box; add an API URL + token for live). Don't ship the integration token to a public browser - front the API with a thin backend proxy, as the doc describes.

---

## Troubleshooting

| Symptom                                              | Cause                                                                     |
| ---------------------------------------------------- | ------------------------------------------------------------------------- |
| `We couldn't access the credential(s)`               | Automated Process User lacks the credential permission set - see step 1   |
| `Not allowed to install or modify metadata via Apex` | Missing user permission _or_ the org-wide Apex Setting - see step 2, both |
| `Variable does not exist: PromptVersionBackfill`     | Org is on a package version earlier than 1.2.0                            |
| Runs stay `Running` forever                          | Watchdog isn't scheduled - see step 3                                     |
| Prompt version panel is blank for some users         | They lack read on `Agent_Prompt_Version__c` - see step 4                  |

Still stuck? [Open a Discussion](https://github.com/BrandonClark65/Apex-Agent-Orchestrator/discussions)
with the run's `Agent_Step__c` trace and I'll take a look.
