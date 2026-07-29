# Apex Agent Orchestrator

**AI agents that live inside Salesforce - built and changed by your admins, not by an outside dev team.**

---

## The situation today

You have AI agents doing real work, and another team builds them for you. That works - but every new
agent, every prompt tweak, every "can it also check the contract file?" is a request, a queue, a
sprint, and a handoff. The knowledge of how your agents behave sits with someone else, and the cost
of a small change is the same as the cost of a big one: a development cycle.

Apex Agent Orchestrator moves that capability in-house. It installs into your existing Salesforce
org as a managed package and turns agent building into **an admin task in a point-and-click app**,
the same way reports, flows, and page layouts already are.

---

## What it does

It is a complete platform for AI agents that **take action**, not just answer questions. An agent
can look up records, read an attached document, create and update data, hand work off to another
agent, and hold a multi-turn conversation with a person - all inside your Salesforce security model.

| Capability | What it means for the business |
| --- | --- |
| **Agents that act, not just chat** | Agents read and write Salesforce data, look up records, read attached documents, and complete real work end to end. |
| **Conversations with memory** | ChatGPT-style threads your people can return to. Agents remember durable facts and preferences across conversations, and learn from what worked and what didn't on previous runs. |
| **Work that finishes** | Long, multi-step jobs aren't cut off by platform limits. An agent takes as many steps as the task needs, and can split work across several agents at once. |
| **Bring your own AI vendor** | OpenAI, Anthropic (Claude), and Azure OpenAI are supported out of the box, chosen per agent from a dropdown. Switching vendors or models is a settings change, not a rebuild - so pricing and model choice stay negotiable. |
| **Cost controls** | Routine background work (summarizing, remembering) can be pointed at a cheaper model while the customer-facing work uses your best one. |
| **Everything is recorded** | Every run and every step is stored as a Salesforce record: what was asked, what the agent did, what it decided, how long it took. Nothing happens in a black box you can't audit. |
| **Reach beyond Salesforce** | One agent can be safely exposed to your public website through a ready-made chat widget, with customer-facing conversations stripped of internal detail and rate-limited per visitor. |
| **Works with what you already build** | Agents can be triggered from Flow, embedded on any record page, or called from other systems - no new platform for your team to learn. |

---

## How easy it is to run - as an admin, not a developer

Everything below happens in the **Agent Orchestrator app**, in the browser, with no code and no
deployment window.

- **Build an agent in a form.** Name it, write its instructions in plain English, pick its AI model
  from a dropdown, and check the boxes for what it's allowed to do. Save. It's live.
- **Change how an agent behaves without fear.** Instructions are versioned automatically. Every
  edit is a numbered, attributable version; published versions can't be silently altered. If v6 made
  things worse, **rollback to v3 is one click and takes effect on the next run** - no deployment, no
  ticket, no waiting.
- **Try before you commit.** A built-in Test Bench runs an agent against a saved sample and shows
  you every step it took. You can run the *same* input against two different versions of the
  instructions and compare the results side by side before making one live.
- **Watch the work happen.** A live Run Monitor lists every run in progress with filters, plus
  **Cancel** and **Re-run** buttons. Click into any run for a step-by-step trace.
- **Manage what agents remember.** A dedicated screen shows every memory an agent holds. Users
  curate their own; admins curate everything, including reviewing the lessons agents draw from their
  own performance before those lessons take effect.
- **See exactly what's granted.** A Tool Catalog lists every capability available and which agents
  have been given it - an access review anyone can read.

**The self-service line is clear:** new instructions, new agents, new permissions, model changes,
memory settings, and rollbacks are all admin work. A developer is needed only to add a genuinely new
*capability* - a new kind of action, such as calling a specific external system.

---

## Control and risk

- **Agents inherit your security model.** Every read and write happens as the person running the
  agent. An agent can never see or change data that user couldn't see or change themselves - your
  existing profiles, permissions, and sharing rules already govern it.
- **Least privilege by default.** Agents get only the capabilities you explicitly grant, one at a
  time, visible on screen.
- **Nothing is exposed publicly by accident.** External access is off unless an admin deliberately
  opts exactly one agent in, and customer-facing transcripts hide all internal reasoning and
  activity.
- **Full audit trail.** Every run records which version of the instructions it executed, so you can
  always answer "why did it do that, back in March?"
- **Self-healing operations.** Background jobs automatically time out stuck work and clean up stale
  data, so nothing hangs unattended.
- **Two roles, ready to assign.** *Admin* (build, monitor, test) and *User* (chat, manage own
  memories).

---

## Why owning it beats renting it

| | Outsourced build team | Apex Agent Orchestrator |
| --- | --- | --- |
| **A wording change to an agent** | Request → backlog → sprint → deploy | An admin edits and saves; live on the next run |
| **Undoing a bad change** | Another ticket, another cycle | One click, instant |
| **A new agent** | A project | An afternoon in a form |
| **Switching AI vendors** | Rework | A dropdown |
| **Who understands your agents** | The other team | Your team |
| **Visibility into what ran** | Whatever they report | Every step, in your own org, always |
| **Where your data goes** | Depends on their architecture | Stays in your Salesforce org, under your controls |

The point isn't that developers stop being useful. It's that **the 90% of agent work that is
wording, permissions, and tuning stops requiring them** - and the remaining 10% gets a proper
framework to build in instead of another one-off.

---

## Getting started

It installs like any other Salesforce package - currently **version 1.2, released and production-ready**.

1. Install the managed package into a sandbox.
2. Connect your AI vendor account (a standard Salesforce credential setup).
3. Give the admin team the *Admin* permission set and the business users the *User* one.
4. Open the **Agent Orchestrator** app and build the first agent.

A proof point is a single agent, not a program: pick one real workflow the other team currently
owns, rebuild it in the app, and compare - including how long the second change to it takes.
