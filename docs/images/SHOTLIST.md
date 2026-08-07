# Screenshots - where each one is used

Captured and in use. This file is the map, so a UI change tells you which docs went stale.

| File                  | Used in                                                            | What it shows                                                                               |
| --------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| `demo.gif`            | `README.md` - hero, above the fold                                 | Full loop: question, tool call, prose answer, records behind Details                        |
| `demo.mp4`            | `README.md` - "higher-quality MP4" link                            | Same cut at 1280px/24fps                                                                    |
| `agent-chat.png`      | Social preview and AppExchange listing (no longer the README hero) | The finished prose answer with Details collapsed                                            |
| `agent-builder1.png`  | `README.md` - app gallery                                          | Provider, memory config, who can use the agent, active prompt version, granted tool schemas |
| `test-bench.png`      | `README.md` - app gallery                                          | Version picker plus the raw LLM request/response in the step trace                          |
| `run-monitor.png`     | `README.md` - app gallery; `docs/INSTALL.md` - "working install"   | The run table, filterable, with statuses and triggers                                       |
| `run-trace1.png`      | `README.md` - app gallery                                          | Agent Run step list: LLM call, tool call, LLM call                                          |
| `prompt-versions.png` | `docs/ARCHITECTURE.md` - Prompt versioning                         | Version history with active/published states and restore actions                            |
| `run-trace2.png`      | `docs/ARCHITECTURE.md` - Prompt versioning                         | Stamped prompt version, token usage, session, sub-agent depth                               |

Two carry the most weight: `demo.gif` is the first thing a visitor sees, and
`prompt-versions.png` is the only reason the versioning section reads as a real feature rather
than a design essay. Re-shoot those first when the UI moves.

The demo GIF is 334KB at 800x375 - small enough to embed inline, because it was encoded from
the MP4 rather than from the raw capture. Going straight from the source screen recording to
GIF produced 7.8MB for the identical 15 seconds; the h264 pass first quantises away the
capture noise that otherwise wrecks palette compression. Worth knowing before you re-cut it.

## Conventions

- **1400-1600px wide**, PNG. Retina looks noticeably better; GitHub scales it down cleanly.
- **Use fake data.** Generate accounts with `scripts/apex/GenerateTestAccounts.apex`. Never a
  real customer name, email, or opportunity value in a public screenshot.
- **Light theme**, default Salesforce styling - familiar beats branded.
- **Crop to the component**, not the whole browser. Nobody needs your tab bar or bookmarks.
- **Always write alt text.** It is the accessibility default and it is what shows if a file
  gets moved or renamed.
- Sizing in `![]()` is ignored by GitHub. Anything that shouldn't be full-bleed needs
  `<img src="..." width="380">` - see the portrait shot in ARCHITECTURE.md.

## Still worth capturing

- **A 20-40 second GIF or MP4** of one full run: type a question, watch the tool chips appear,
  final answer lands. Worth more than any static shot, and it is the asset that makes a
  Reddit or LinkedIn launch post work at all. Keep a GIF under ~10MB; for longer, upload an
  MP4 to a release or issue and link it - GitHub plays video inline in markdown.
- **A social preview image** (1280x640, Settings - Social preview). This is what renders when
  the repo is linked in Slack or LinkedIn; it is a grey placeholder until set.
- **Memories and Tool Catalog tabs** - the two app surfaces with no screenshot yet.
