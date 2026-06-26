# Apex Agent Orchestrator (AAO)

A Salesforce‑native framework for building, running, and monitoring AI agents that take actions across Salesforce and external systems.

## What This Project Is
A managed‑package‑ready orchestration layer that enables:
- Multi‑step agent reasoning
- Apex‑based tool execution
- LLM provider abstraction (OpenAI, Azure, Anthropic, etc.)
- Memory integration (Salesforce data + external vector stores)
- Full execution logging and observability
- Admin‑configurable agents via Custom Metadata

## Core Components
- **AgentRunner** — Executes agent loops and manages LLM interactions.
- **ToolRegistry** — Discovers and invokes Apex tools.
- **LLMClient** — Provider‑agnostic LLM interface.
- **ExecutionLogger** — Stores reasoning, steps, and results.
- **Custom Metadata** — Defines agents, tools, and provider configs.
- **LWCs** — Agent Builder UI, Execution Viewer, Tool Catalog.

## Package Layout
force-app/
main/
default/
classes/
lwc/
customMetadata/
permissionsets/


## Post-Install Setup

### Grant the Automated Process User access to LLM credentials
Agent steps are chained via a Platform Event (`Agent_Step_Event__e`) so that long-running agents aren't limited by Apex's queueable chain-depth cap. As a side effect, the Queueable that performs the LLM callout is enqueued from the event trigger and therefore executes as the **Automated Process User**, not the user who started the run.

If your LLM provider's Named/External Credential (e.g. `OpenAI_Credential`) uses per-principal access control, you'll see a run fail with:

> We couldn't access the credential(s). You might not have the required permissions, or the external credential "..." might not exist.

To fix this, after installing the package:
1. Setup → Named Credentials → External Credentials → select your LLM provider's external credential.
2. Note the permission set(s) listed under **Permission Set Mappings**.
3. The Automated Process User is a restricted system user — you cannot open its User Detail page (you'll get an "Insufficient Privileges" error if you try). Instead, assign the permission set from the **permission set's** side:
   - Setup → Permission Sets → open the permission set with the External Credential Principal Access mapping.
   - Click **Manage Assignments** → **Add Assignment**.
   - Search for and select the **Automated Process** user, then save.
   - If the Automated Process user doesn't appear in that list for some reason, it can also be assigned via anonymous Apex:
     ```apex
     User automatedProcessUser = [SELECT Id FROM User WHERE UserType = 'AutomatedProcess' LIMIT 1];
     PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'YOUR_PERMISSION_SET_NAME' LIMIT 1];
     insert new PermissionSetAssignment(AssigneeId = automatedProcessUser.Id, PermissionSetId = ps.Id);
     ```

If your external credential uses **Per-User** authentication, switch it to a **Named Principal** instead — the Automated Process User cannot complete a per-user OAuth flow.

## Roadmap
- Agent execution loop (MVP)
- Tool interface + registry
- LLM provider abstraction
- Execution logs + dashboard
- Memory integration
- Sample agents
- Managed package release


