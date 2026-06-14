# Apex Agent Orchestrator (AAO)

A Salesforce‑native framework for building, running, and monitoring AI agents that take actions across Salesforce and external systems.

## 🚀 What This Project Is
A managed‑package‑ready orchestration layer that enables:
- Multi‑step agent reasoning
- Apex‑based tool execution
- LLM provider abstraction (OpenAI, Azure, Anthropic, etc.)
- Memory integration (Salesforce data + external vector stores)
- Full execution logging and observability
- Admin‑configurable agents via Custom Metadata

## 🧩 Core Components
- **AgentRunner** — Executes agent loops and manages LLM interactions.
- **ToolRegistry** — Discovers and invokes Apex tools.
- **LLMClient** — Provider‑agnostic LLM interface.
- **ExecutionLogger** — Stores reasoning, steps, and results.
- **Custom Metadata** — Defines agents, tools, and provider configs.
- **LWCs** — Agent Builder UI, Execution Viewer, Tool Catalog.

## 📦 Package Layout
force-app/
main/
default/
classes/
lwc/
customMetadata/
permissionsets/


## 🛠️ Roadmap
- Agent execution loop (MVP)
- Tool interface + registry
- LLM provider abstraction
- Execution logs + dashboard
- Memory integration
- Sample agents
- Managed package release


