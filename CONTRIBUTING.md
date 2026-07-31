# Contributing

Thanks for considering it. This is a small project maintained by one person, so the process is
light.

## Read this first: you probably can't deploy this locally

The source hardcodes the `aao__` namespace prefix in about 40 files, and the `aao` namespace is
registered to the maintainer's Dev Hub. Namespaces are globally unique and can't be shared, so
**you cannot deploy this source into your own scratch org**. That is a limitation of how the
package is built, not a policy about who may contribute.

What that means in practice:

| You can                                                    | Only the maintainer can              |
| ---------------------------------------------------------- | ------------------------------------ |
| Read the source and propose changes                        | Deploy to a namespaced scratch org   |
| Run `npm run lint` and `npm run test:unit` (no org needed) | Run the Apex tests                   |
| Write Apex, LWC, and docs                                  | Cut and promote package versions     |
| Test LWC behaviour with jest                               | Verify a change end to end in an org |

So: **write the change and the tests, verify what you can, and say in the PR what you weren't
able to run.** The maintainer runs the Apex suite in a namespaced org before merging. Nobody
will hold an unverifiable Apex change against you - just be explicit about it rather than
implying it was tested.

If this constraint is blocking something you want to build, open a Discussion. Making the
source namespace-agnostic is possible and would remove it.

## Before you start

For anything larger than a bug fix, **open an issue or Discussion first**. Some things are
deliberate design decisions rather than oversights - prompt versions being records rather than
Custom Metadata, for example, or the chat renderer's JSON fallback - and I'd rather save you
the work than reject a PR. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the reasoning
behind most of them.

## Workflow

1. Fork the repo and branch from `main`.
2. Make your change.
3. Run what you can (below).
4. Open a PR against `main`, filling in the template. Say what you ran and what you couldn't.

## What you can verify

```bash
npm install
npm run lint          # eslint on the LWC js files
npm run test:unit     # LWC jest
npx prettier --write <the files you changed>
```

**Don't run `npm run prettier` across the whole repo.** Roughly 270 files predate the current
prettier config, mostly packaged metadata XML, so a repo-wide format buries your change in an
unrelated diff. Format only what you touched.

CI runs lint and the jest suite on every PR. Apex tests aren't in CI, because they need a
namespaced org and secrets that forks can't access.

## Conventions

- **User mode everywhere.** All tool SOQL and DML runs in user mode. The framework's entire
  security model rests on this - a PR that bypasses it won't be merged without a very good
  reason, stated explicitly.
- **Agents answer with `final.message`.** Any change to an agent prompt has to keep the prose
  key, or the chat window renders a JSON dump. See
  [the final-answer contract](docs/ARCHITECTURE.md#the-final-answer-contract).
- **ApexDoc on public surfaces.** Add or update `@description` / `@param` / `@return` on any
  public class, method, or constructor you touch, so `npm run docs` stays accurate.
- **Tests for new behaviour.** New tools and engine paths need real coverage, not just enough
  to clear the 75% packaging gate.
- **Don't break subscribers.** Renaming or removing packaged components breaks every installed
  org. Fields on packaged Custom Metadata are `SubscriberControlled` deliberately. Flag any
  breaking change in the PR.
- **Hyphens, not em dashes**, in every markdown file. [CLAUDE.md](CLAUDE.md) has the full
  writing conventions and a check command.

A pre-commit hook (husky + lint-staged) formats and lints staged files automatically.

## Good contributions

**A new tool** is the most useful thing you can add, and the smallest: one Apex class
implementing `AgentTool`, plus two Custom Metadata records. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#writing-your-own-tool).

**A new LLM provider** is one `LLMClient` implementation, one branch in `LLMClientFactory`, and
an `LLM_Provider__mdt` example record. Follow `AnthropicClient` as the model.

**Bug reports with a step trace** are worth as much as patches. Run Monitor, open the run, copy
the `Agent_Step__c` timeline - most bugs are diagnosable from it alone.

**Docs fixes**, especially to [docs/INSTALL.md](docs/INSTALL.md). If something in the setup
tripped you up, it will trip up the next person; a PR that fixes the wording is genuinely
valuable and needs no org at all.

## Maintainer reference

Not needed to contribute - here so the workflow is documented rather than tribal knowledge.

The `npm run org:*` scripts assume the `aao` namespace registry org is linked to your Dev Hub:

```bash
npm run org:setup     # create scratch org, deploy, assign AAO_Admin, schedule jobs, open
npm run org:deploy    # push changes; data in your objects persists
npm run org:redeploy  # unschedules the jobs first, for changes to the Schedulables
```

Iterate with source deploys rather than reinstalling the package: uninstalling a managed
package deletes its custom objects and every record in them.

Full Apex suite, required before cutting a version:

```bash
sf apex run test --target-org <alias> --code-coverage --result-format human
```

Coverage must stay at or above 75% or `sf package version create` fails. Release process is in
[docs/PACKAGING.md](docs/PACKAGING.md).
