# Packaging Guide — Apex Agent Orchestrator (2GP)

How to cut and release new versions of the **second-generation managed package (2GP)**
`Apex Agent Orchestrator` (package id `0Hofj0000002LpxCAE`, namespace `aao`).

All commands are **single-line PowerShell** (this repo's shell). Bash-style `\`
line continuations will not work here — keep each command on one line or use a
backtick (`` ` ``) to continue.

---

## Orgs and their roles

| Org | Alias | Role | Rule |
|-----|-------|------|------|
| **Dev Hub** | `DevHub` | Owns the `0Ho` package, all versions, and the namespace-registry link. Every `version create` / `promote` runs here. | Keep alive; don't lose access. Log in periodically so a DE org isn't deactivated. |
| **Namespace org** | `aao` | Owns the `aao` namespace, linked to the Dev Hub. (Also the retired 1GP packaging org.) | Don't delete; don't unlink the namespace. A namespace binds to exactly one Dev Hub. |
| **Repo** | — | Source of truth for all metadata. | This is the day-to-day working surface. |
| **Scratch orgs** | `2gp-test` etc. | Disposable dev / test environments. | Create, test, delete freely. |

> Verify the aliases with `sf org list`. Substitute your real Dev Hub alias for
> `DevHub` throughout if different.

---

## Standard release workflow

### 0. Pre-flight

Make sure tests pass before spending time on a build — `version create` enforces
75% Apex coverage across the package and fails late if you're short.

```powershell
sf apex run test --target-org aao --code-coverage --result-format human
```

### 1. Set the ancestor (REQUIRED for every version after 1.0)

For a managed 2GP package, **a new version is upgradeable by subscribers only if
it declares the previous *released* version as its ancestor.** Skip this and
subscribers on the old version cannot upgrade in place — they'd have to uninstall
(losing data) and reinstall.

Edit `sfdx-project.json` → the `force-app` entry in `packageDirectories`. Add
`ancestorVersion` set to the **highest promoted (Released) version number**:

```jsonc
{
  "path": "force-app",
  "default": true,
  "package": "Apex Agent Orchestrator",
  "versionName": "ver 1.1",
  "versionNumber": "1.1.0.NEXT",
  "ancestorVersion": "1.0.0.1"   // <-- the last RELEASED version (major.minor.patch.build)
}
```

Notes:
- The **very first** version (1.0) has **no** ancestor — it's the root. Every
  version after that needs one.
- The ancestor must be a **promoted/Released** version, and it must be the
  highest promoted version.
- You can use `ancestorId` (a `04t...` id or a `packageAliases` entry) instead of
  `ancestorVersion`.
- The `HIGHEST` keyword appears in Salesforce docs but is **broken in the CLI** —
  always specify the explicit version number.

### 2. Create the version

```powershell
sf package version create --package "Apex Agent Orchestrator" --code-coverage --installation-key-bypass --wait 30 --target-dev-hub DevHub
```

Returns a `04t...` Subscriber Package Version Id. This new version is a **Beta**
until promoted. Save the `04t` id.

### 3. Test-install in a clean scratch org

Proves the package deploys on its own, independent of your dev org's state.

```powershell
sf org create scratch --definition-file config/project-scratch-def.json --alias 2gp-test --target-dev-hub DevHub --set-default
sf package install --package 04tXXXXXXXXXXXX --wait 20 --publish-wait 20 --target-org 2gp-test
sf org assign permset --name AAO_Admin --target-org 2gp-test
sf org open --target-org 2gp-test
```

Click through the app (tabs, permission sets, a sample agent run) to confirm it works.

### 4. Promote to Released

Only a **Released** version can be installed in production and can serve as an
upgrade source. **Promotion is permanent** — components in a released version can
never be removed (only deprecated). Test first.

```powershell
sf package version promote --package 04tXXXXXXXXXXXX --target-dev-hub DevHub
```

### 5. Clean up + commit

```powershell
sf org delete scratch --target-org 2gp-test --no-prompt
```

Commit the bumped `sfdx-project.json` (version number + ancestor) so the lineage
is recorded in git.

---

## Subscriber upgrade rules

| Scenario | In-place upgrade? | Data kept? |
|----------|-------------------|------------|
| Released → newer Released **with ancestor set** | ✅ Yes | ✅ Yes |
| Released → newer Released **ancestor NOT set** | ❌ No — new root; must uninstall first | ❌ Lost |
| Beta installed (dev/sandbox) → any version | ❌ No — Beta isn't upgradeable; uninstall first | ❌ Lost |

Takeaways:
- Real subscribers only ever install **Released** versions and upgrade in place —
  **as long as you always set the ancestor** (Step 1).
- Betas are for *your* testing only; uninstall them before installing another.
- To upgrade a subscriber, just send them the new version's install URL/id; they
  install over the top.

---

## Useful commands

```powershell
# List all versions of the package (see which are Released vs Beta, and ancestry)
sf package version list --package "Apex Agent Orchestrator" --target-dev-hub DevHub

# Detailed report on one version
sf package version report --package 04tXXXXXXXXXXXX --target-dev-hub DevHub

# List all packages in the Dev Hub
sf package list --target-dev-hub DevHub

# Get the install URL for a version
#   https://login.salesforce.com/packaging/installPackage.apexp?p0=04tXXXXXXXXXXXX

# Install into any org
sf package install --package 04tXXXXXXXXXXXX --wait 20 --publish-wait 20 --target-org <alias>

# Uninstall (needed before reinstalling a Beta)
sf package uninstall --package 04tXXXXXXXXXXXX --target-org <alias>

# Delete a Beta version you no longer want (Released versions can't be deleted)
sf package version delete --package 04tXXXXXXXXXXXX --target-dev-hub DevHub
```

---

## Version numbering

`major.minor.patch.build` (e.g. `1.1.0.NEXT`).
- `NEXT` in the build slot auto-increments each `version create`.
- Bump **major/minor** for feature releases, **patch** for patch versions.
- `versionName` is a human label ("Summer Release"); the number is what enforces
  ordering. Upgrades must go to a **higher** version number.

---

## Gotchas specific to this repo

- **Scheduled jobs block class deploys.** The `aao` dev org typically has
  `AgentWatchdogSchedulable` and `MemoryJanitorSchedulable` cron jobs. Salesforce
  refuses to deploy a class referenced by a scheduled job — unschedule those crons
  before deploying engine classes, then reschedule. (Fresh scratch-org installs are
  unaffected.)
- **2GP validates the whole metadata graph.** Unlike scratch/1GP builds, a
  dangling reference (a tab, field, or FLS entry pointing at something not in
  source) fails `version create`. Example already hit: `Agent_Run__c` /
  `Agent_Step__c` tabs referenced by the app + `AAO_Admin` permission set but
  missing from `force-app/main/default/tabs/`. Fix = add the missing metadata.
- **75% coverage gate.** `--code-coverage` fails the build if package Apex coverage
  is under 75%. Run the test suite first.
- **Namespace is real now.** `sfdx-project.json` has `"namespace": "aao"`, so
  scratch orgs come up with the `aao` namespace and metadata lines up automatically.

---

## One-time setup (already done — for reference)

1. Enabled Dev Hub + Namespace Registry in the Dev Hub org.
2. Registered the `aao` namespace to the Dev Hub.
3. `sf package create --name "Apex Agent Orchestrator" --package-type Managed --path force-app --target-dev-hub DevHub`
   (created the `0Ho` package, wrote it into `sfdx-project.json`).
4. First `version create` + scratch-org test.

The old 1GP package (`033bm000000U58j`, Beta-only, single dev-org install) was
**abandoned**, not converted — there were no production subscribers to preserve an
upgrade path for, so a fresh 2GP under the same namespace was the clean route.
