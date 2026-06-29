#!/usr/bin/env bash
# azd preprovision hook — auto-bind required env vars from the active Azure CLI context.
#
# Runs automatically before `azd provision` / `azd up` (wired in `azure.yaml`).
# The `azure.ai.agents` azd extension this template uses requires
# AZURE_SUBSCRIPTION_ID to be present in the azd env before provisioning;
# this hook reads the subscription from `az account show` and sets it for
# you so you don't have to.
#
# AZURE_LOCATION is prompted interactively if missing.
set -euo pipefail

# ── AZURE_SUBSCRIPTION_ID ───────────────────────────────────────────────────

current_sub="$(azd env get-value AZURE_SUBSCRIPTION_ID 2>/dev/null || true)"
if [ -z "${current_sub}" ]; then
  if ! sub_id="$(az account show --query id --output tsv 2>/dev/null)"; then
    echo "ERROR: AZURE_SUBSCRIPTION_ID is not set and 'az account show' failed." >&2
    echo "Run: az login" >&2
    exit 1
  fi
  sub_name="$(az account show --query name --output tsv 2>/dev/null || echo '?')"
  echo "Binding azd env to subscription: ${sub_name} (${sub_id})"
  azd env set AZURE_SUBSCRIPTION_ID "${sub_id}" >/dev/null
else
  echo "AZURE_SUBSCRIPTION_ID already set: ${current_sub}"
fi

# ── AZURE_LOCATION ──────────────────────────────────────────────────────────

current_loc="$(azd env get-value AZURE_LOCATION 2>/dev/null || true)"
if [ -z "${current_loc}" ]; then
  default_loc='eastus2'
  read -r -p "AZURE_LOCATION not set. Enter Azure region [${default_loc}]: " loc
  loc="${loc:-${default_loc}}"
  echo "Setting AZURE_LOCATION = ${loc}"
  azd env set AZURE_LOCATION "${loc}" >/dev/null
else
  echo "AZURE_LOCATION already set: ${current_loc}"
fi
