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

- Sentence case for headings, not Title Case (`## Orgs and their roles`).
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
npm run lint          # eslint on the 14 LWC js files
npm run test:unit     # LWC jest, 5 suites
```

CI (`.github/workflows/ci.yml`) runs exactly these two on every PR, nothing more.

Apex tests need a real org and **cannot run in a sandboxed session**:

```bash
sf apex run test --target-org <alias> --code-coverage --result-format human
```

If you changed Apex or packaged metadata and couldn't run those, **say so explicitly** rather
than implying the change is verified. Coverage must stay at or above 75% or
`sf package version create` fails.

**Don't run `npm run prettier` repo-wide as a side effect.** Roughly 270 files predate the
current prettier config (`npm run prettier:verify` to see the live count), the large majority
of them packaged metadata XML. A repo-wide format is therefore a huge diff that needs a
scratch-org deploy to verify, so it belongs in its own commit. Format only the files you
touched - `npx prettier --write <paths>`. This is also why the prettier check is commented out
of CI rather than enabled.

## Docs live in specific places

| Change                     | Also update                                                                                                                        |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| New tool or LLM provider   | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)                                                                                       |
| Install or setup behavior  | [docs/INSTALL.md](docs/INSTALL.md)                                                                                                 |
| Anything visible in the UI | [docs/images/SHOTLIST.md](docs/images/SHOTLIST.md) - it maps each screenshot to the docs using it, so you can tell what went stale |
| Public Apex surface        | ApexDoc `@description` / `@param` / `@return`, so `npm run docs` stays accurate                                                    |

Keep the README lean. It is a landing page, not a manual - deep detail belongs in `docs/`.

## Releasing a package version

[docs/PACKAGING.md](docs/PACKAGING.md) is the build procedure (ancestor, create, scratch-org
test, promote). What that doc doesn't cover is the doc sweep afterwards. **Only a promoted
(Released) version gets published** - never point these at a Beta `04t` id.

`sf package version create` writes the new `04t` id into `packageAliases` in
`sfdx-project.json` itself, so read the id from there rather than scrolling back through CLI
output. Then update, in one commit:

| File                               | What changes                                                                                                                              |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `sfdx-project.json`                | `versionName` / `versionNumber` bumped to the **next** release, `ancestorVersion` set to the one just promoted, new `packageAliases` entry |
| [README.md](README.md)             | version badge, "Current version:" line, **both** install links, the roadmap bullet (`v1.4 Released`)                                       |
| [docs/INSTALL.md](docs/INSTALL.md) | "Current version:" line, **both** install links                                                                                           |
| [SECURITY.md](SECURITY.md)         | supported-versions table (`1.4.x` supported, `< 1.4` upgrade)                                                                             |

Four files, five install-link occurrences. `grep -rn "installPackage.apexp" --include=*.md`
catches any that were missed; the only legitimate leftover is the `04tXXXXXXXXXXXX`
placeholder in `docs/PACKAGING.md`.

Two things that are easy to get wrong:

- **Don't bump every version number you find.** Some record when a feature arrived, not what
  the current release is. The `PromptVersionBackfill` "requires 1.2.0 or later" notes in
  `docs/INSTALL.md` are the standing example - bumping those makes the docs wrong.
- **Add an upgrade note to `docs/INSTALL.md` only when upgrading is not transparent.** The
  1.3.0 note exists because the prompt fix silently does nothing for agents that already have
  `Agent_Prompt_Version__c` records, which reads as the fix being broken. A feature that
  defaults to today's behavior for existing installs needs no note.

Patch versions (a non-zero third digit, `1.3.1`) are **rejected** - `version create` fails with
"Can't create patch version" unless Salesforce enables patch versioning for the namespace org
via a Partner Community case. Every release so far has been a minor bump.

## Screenshots and demo media

Encode GIFs **from the MP4, not the raw screen capture**. Going straight from a capture
produced 7.8MB where the MP4 route produced 334KB for identical frames - the h264 pass
quantises away capture noise that otherwise defeats palette compression. Recipe and timings
are in [docs/images/SHOTLIST.md](docs/images/SHOTLIST.md).
