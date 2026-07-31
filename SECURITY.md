# Security Policy

## Reporting a vulnerability

**Please don't open a public issue for security problems.**

Email **clark.brandon.98@gmail.com** with:

- What the issue is and roughly how severe you think it is
- Steps to reproduce, or a proof of concept
- The package version or commit you found it on

I'll acknowledge within a few days. This is a single-maintainer project, so I can't promise
an enterprise response time - but security reports go to the front of the queue, and I'll keep
you posted on the fix and tell you when a patched package version is out.

If you'd like credit in the release notes, say so; otherwise reports stay anonymous.

## Supported versions

Fixes go into the latest released package version. Because 2GP managed package versions are
upgraded in place, the fix path is "install the new version" rather than a backport.

| Version | Supported  |
| ------- | ---------- |
| 1.2.x   | ✅         |
| < 1.2   | ❌ upgrade |

## Security model, in brief

Worth understanding before you report - some behavior is intentional:

- **Tools run in user mode.** All tool SOQL and DML executes as the running user, so an agent
  can only read or write what that user could. If you find a tool path that escapes user mode,
  that's a genuine vulnerability - please report it.
- **Agents are as powerful as their grants.** An agent with `UpdateRecordTool` granted, run by
  a System Administrator, can update anything that admin can. This is by design; scope agents
  with least-privilege users and narrow tool grants.
- **The external REST API is a deliberate widening.** `AgentChatApi` runs as one integration
  user. Its blast radius is whatever that user can see, which is why
  [docs/EXTERNAL-ACCESS.md](docs/EXTERNAL-ACCESS.md) insists on least privilege.
- **Prompts reach an external LLM.** Record data included in a prompt leaves your org for
  whichever provider you configured. There is no PII masking layer in this package today -
  if you need one, that's on you to add before pointing agents at sensitive data. Worth
  saying plainly rather than burying.
- **Don't ship integration tokens to browsers.** The example widget is a demo; front it with
  a backend proxy.

## Out of scope

- Vulnerabilities in Salesforce itself - report those to
  [Salesforce](https://www.salesforce.com/company/disclosure/).
- Vulnerabilities in your LLM provider.
- Agents doing something unwanted because of an overly broad tool grant or an overly
  privileged running user. That's configuration - though if the docs led you there, tell me
  and I'll fix the docs.
