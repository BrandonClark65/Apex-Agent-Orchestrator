# Working in this repo

## Writing style

**Never use em dashes (U+2014) or en dashes (U+2013). Use a plain hyphen `-` instead.**

Applies to everything you write: markdown docs, code comments, ApexDoc, commit messages, PR
descriptions, agent system prompts, and UI strings.

**Every `.md` file in the repo is swept clean and must stay that way.** Check before you
commit - this should print nothing:

```bash
# chr(8212) is the em dash, chr(8211) the en dash - spelled this way so this file passes its own check
python3 -c "import subprocess; [print(f) for f in subprocess.run(['git','ls-files','*.md'],capture_output=True,text=True).stdout.split() if any(c in open(f,encoding='utf-8').read() for c in (chr(8212), chr(8211)))]"
```

Existing `.cls`, `.js`, `.html`, and `.xml` files still contain them in comments and packaged
prompts. That is intentional and was left alone on purpose - **do not bulk-replace dashes
outside markdown.** Fix them only in lines you were already editing for another reason.

Other conventions:

- Sentence case for headings, not Title Case.
- Prefer plain words over jargon, and don't oversell. The docs deliberately state tradeoffs
  ("there is no vendor SLA behind this") rather than hiding them.

## Things that will trip you up

**Prompt changes don't take effect the way you'd expect.**
`Agent_Definition__mdt.SystemPrompt__c` is only the _packaged baseline_ - the fallback used
when an agent has no `Agent_Prompt_Version__c` records at all. Editing the CMDT does nothing
for an agent that already has versions; those need a new version saved and activated in the
Agent Builder. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#prompt-versioning).

**Agents must answer with `final.message`.**
`{"final": {...}}` renders as a JSON dump unless it carries a prose key. Any new or edited
agent prompt has to require `message` and put records in sibling keys. See
[the final-answer contract](docs/ARCHITECTURE.md#the-final-answer-contract).

**All tool SOQL and DML runs in user mode.** The framework's entire security model rests on
this. Don't bypass it without a very good reason, stated explicitly.

**Renaming or removing packaged components breaks every installed org.** Fields on packaged
Custom Metadata are `SubscriberControlled` deliberately. Call out any breaking change.

**Braces appear inside string literals** (`QuerySalesforceTool` strips trailing `}` artifacts),
so counting braces is not a valid syntax check.

## Verifying changes

```bash
npm run lint          # eslint on LWC - note the package.json glob is unreliable,
                      # `npx eslint force-app` is the dependable form
npm run test:unit     # LWC jest
```

Apex tests need a real org and **cannot run in a sandboxed session**:

```bash
sf apex run test --target-org <alias> --code-coverage --result-format human
```

If you changed Apex or packaged metadata and couldn't run those, **say so explicitly** rather
than implying the change is verified. Coverage must stay at or above 75% or
`sf package version create` fails.

**Don't run `npm run prettier` repo-wide as a side effect.** 278 files predate the current
prettier config, so a repo-wide format produces a huge diff touching 233 metadata XML files.
That cleanup is its own commit, and it needs a scratch-org deploy to verify. Format only the
files you touched. This is also why the prettier check is commented out of CI.

## Docs live in specific places

| Change                     | Also update                                                                                                                        |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| New tool or LLM provider   | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)                                                                                       |
| Install or setup behavior  | [docs/INSTALL.md](docs/INSTALL.md)                                                                                                 |
| Anything visible in the UI | [docs/images/SHOTLIST.md](docs/images/SHOTLIST.md) - it maps each screenshot to the docs using it, so you can tell what went stale |
| Public Apex surface        | ApexDoc `@description` / `@param` / `@return`, so `npm run docs` stays accurate                                                    |

Keep the README lean. It is a landing page, not a manual - deep detail belongs in `docs/`.

## Screenshots and demo media

Encode GIFs **from the MP4, not the raw screen capture**. Going straight from a capture
produced 7.8MB where the MP4 route produced 334KB for identical frames - the h264 pass
quantises away capture noise that otherwise defeats palette compression. Recipe and timings
are in [docs/images/SHOTLIST.md](docs/images/SHOTLIST.md).
