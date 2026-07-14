#!/usr/bin/env bash
#
# Bootstraps a namespaced (aao) scratch org for source-driven development, so you
# can iterate with `sf project deploy start` instead of uninstalling/reinstalling
# the managed package (which wipes all data in the packaged objects).
#
# Prerequisites (one-time):
#   1. A Dev Hub org, authorized:  sf org login web --set-default-dev-hub --alias DevHub
#   2. The `aao` namespace (from sfdx-project.json) registered in a namespace
#      registry org and that org LINKED to your Dev Hub. Without the link,
#      `sf org create scratch` fails because the source references `aao__...`.
#      See: https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_reg_namespace.htm
#
# Usage:  npm run org:setup      (or:  bash scripts/create-dev-org.sh [alias])
#
set -euo pipefail

ALIAS="${1:-aaoDev}"

echo "==> Creating scratch org '$ALIAS' (30 days)..."
sf org create scratch \
  --definition-file config/project-scratch-def.json \
  --alias "$ALIAS" \
  --set-default \
  --duration-days 30

echo "==> Deploying source..."
sf project deploy start --target-org "$ALIAS"

echo "==> Assigning AAO_Admin permission set..."
sf org assign permset --name AAO_Admin --target-org "$ALIAS"

echo "==> Scheduling watchdog + memory janitor..."
sf apex run --file scripts/apex/ScheduleWatchdog.apex --target-org "$ALIAS"

echo "==> Done. Opening org..."
sf org open --target-org "$ALIAS"

cat <<EOF

Dev loop from here on (no reinstall, data persists across deploys):
  npm run org:deploy      # push source changes
  npm run org:redeploy    # unschedule jobs first (needed if a deploy touches
                          # AgentWatchdogSchedulable / MemoryJanitorSchedulable)
  npm run org:open        # open the org

Named credentials for LLM providers are NOT created by this script -- add the
ones you use (OpenAI_NC / Anthropic_NC / AzureOpenAI_NC) per the README's
Post-Install Setup, and set Model_Name__c to your own deployment name.
EOF
