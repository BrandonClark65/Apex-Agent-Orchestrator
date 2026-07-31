# Contributing

Thanks for considering it. This is a small project maintained by one person, so the process is
light.

## Before you start

For anything larger than a bug fix, **open an issue or Discussion first**. Some things are
deliberate design decisions rather than oversights (prompt versions being records rather than
Custom Metadata, for example - see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#prompt-versioning)),
and I'd rather save you the work than reject a PR.

## Dev setup (source-driven scratch org)

When you're working on the package itself, **don't** iterate by reinstalling the managed package - uninstalling a managed package deletes its custom objects and every record in them (agent runs, memories, sessions, and any edits to the shipped Custom Metadata), and 1GP Beta versions can't be upgraded in place, so a reinstall is your only option. Instead, deploy source straight into a scratch org and redeploy on each change; metadata deploys never drop your objects or data.

**One-time prerequisites:**

1. A Dev Hub, authorized: `sf org login web --set-default-dev-hub --alias DevHub`
2. The `aao` namespace (from `sfdx-project.json`) registered in a namespace registry org, and that org **linked to your Dev Hub**. This is required because the source references `aao__` components throughout - without the namespace, `sf org create scratch` and the deploy will fail. See [Create and Register Your Namespace](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_reg_namespace.htm).

> Contributors without a namespace registry org: say so on the issue. Most changes can be
> reviewed against a fork without the namespace, and I can run the packaged build.

**Bootstrap a fresh dev org** (create → deploy → assign `AAO_Admin` → schedule jobs → open):

```bash
npm run org:setup
```

**Inner loop** - edit source, then:

```bash
npm run org:deploy      # push changes; data in your objects persists
npm run org:open
```

If a deploy touches `AgentWatchdogSchedulable` or `MemoryJanitorSchedulable`, the scheduled jobs block class deployment - use `npm run org:redeploy`, which unschedules them first (re-run `npm run org:schedule` afterward). The `org:setup` bootstrap does **not** create the LLM named credentials; add the ones you use per [docs/INSTALL.md](docs/INSTALL.md).

## Before you open a PR

```bash
npm run prettier:verify    # formatting
npm run lint               # eslint on LWC
npm run test:unit          # LWC jest tests
sf apex run test --target-org <alias> --code-coverage --result-format human
```

Apex coverage must stay at or above **75%** across the package - `sf package version create`
enforces it and fails late if you're short.

A pre-commit hook (husky + lint-staged) formats and lints staged files automatically.

## Conventions

- **User mode everywhere.** All tool SOQL and DML runs in user mode. The framework's entire
  security model rests on this - a PR that bypasses it won't be merged without a very good
  reason.
- **ApexDoc on public surfaces.** Add or update `@description` / `@param` / `@return` on any
  public class, method, or constructor you touch, so `npm run docs` stays accurate.
- **Tests for new behavior.** New tools and engine paths need coverage, not just enough to
  clear the 75% gate.
- **Don't break subscribers.** Fields on packaged Custom Metadata are `SubscriberControlled`
  for a reason. Renaming or removing packaged components is a breaking change for every
  installed org - flag it explicitly in the PR.

## Adding a new tool

The most useful contributions. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#writing-your-own-tool) - it's one Apex class plus
two Custom Metadata records.

## Adding an LLM provider

One `LLMClient` implementation plus one branch in `LLMClientFactory`, plus an
`LLM_Provider__mdt` example record. Follow `AnthropicClient` as the model.

## Releases

Package versions are cut by the maintainer - see [docs/PACKAGING.md](docs/PACKAGING.md).
Contributors don't need to touch `sfdx-project.json`.
