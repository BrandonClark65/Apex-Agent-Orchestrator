# Screenshot shot list

The repo currently has **no screenshots**, and that is the single biggest thing holding back
adoption. Salesforce architects and admins evaluate visually — a wall of prose about a
"ReAct loop chained by platform events" converts far worse than one picture of a working chat
window with tool chips in it.

Capture these five from a scratch org with the demo agent, drop the PNGs in this folder, and
uncomment the image block near the top of the README.

| #   | File                | What to capture                                                                                                        | Why it matters                                                                                                    |
| --- | ------------------- | ---------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| 1   | `agent-chat.png`    | **Agent Chat** mid-run: a real question, the live "Calling QuerySalesforceTool…" progress, tool activity chips visible | The hero shot. This is the one that goes at the top of the README. It proves the thing is real in under a second. |
| 2   | `run-trace.png`     | **Agent Run** record page: step timeline expanded to show an LLM request/response                                      | Sells the observability story — the thing Agentforce users complain they don't get                                |
| 3   | `agent-builder.png` | **Agents** tab: an agent's tool grants + the prompt version history panel                                              | Shows admins it's configurable without code                                                                       |
| 4   | `test-bench.png`    | **Test Bench** running an input with the live step trace, ideally with a version picker visible                        | Shows the dev loop                                                                                                |
| 5   | `run-monitor.png`   | **Run Monitor** with a filled table, a couple of statuses, Cancel/Re-run actions                                       | Shows it's operable at scale                                                                                      |

## Guidance

- **1400–1600px wide**, PNG. Retina looks noticeably better; GitHub scales it down cleanly.
- **Use fake data.** Generate accounts with `scripts/apex/GenerateTestAccounts.apex`. Never a
  real customer name, email, or opportunity value in a public screenshot.
- **Light theme**, default Salesforce styling — familiar beats branded.
- **Crop to the component**, not the whole browser. Nobody needs your tab bar or bookmarks.
- Blur or replace your username and org name in the header.

## Worth more than all five

A **20–40 second GIF or MP4** of one full run: type a question → watch tool chips appear →
final answer lands. Record with the Run Monitor or trace visible if you can fit it.

Keep a GIF under ~10MB or GitHub gets slow to load it; for anything longer, upload an MP4 to
the release notes or a GitHub issue and link it from the README — GitHub hosts video in
markdown and it plays inline.
