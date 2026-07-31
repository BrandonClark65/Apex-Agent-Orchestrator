## What this changes

<!-- One or two sentences. Link the issue if there is one: Fixes #123 -->

## Why

<!-- What problem does this solve? Skip if it's obvious from the above. -->

## How it was tested

<!-- Scratch org? Which agent/tool did you exercise? Paste the step trace if it's behavioral. -->

## Checklist

Things anyone can do:

- [ ] `npm run lint` passes
- [ ] `npm run test:unit` passes
- [ ] Ran `npx prettier --write` on the files I changed (not the whole repo)
- [ ] ApexDoc updated on any public class/method I touched
- [ ] Tool SOQL/DML still runs in **user mode**
- [ ] No breaking change to packaged components - or it's called out below

Apex tests need the `aao` namespace, so contributors can't run them - see
[CONTRIBUTING.md](../CONTRIBUTING.md). Tick this only if you actually could:

- [ ] Apex tests pass in a namespaced org and coverage is still ≥ 75%
- [ ] N/A - no org available, Apex not verified

## Breaking changes

<!-- Renaming or removing packaged metadata breaks every installed org. Say so here, or "None". -->

None.
