#!/usr/bin/env bash
# azd preprovision hook — interactive setup for AZURE_SUBSCRIPTION_ID,
# AZURE_LOCATION, and the Foundry model deployment.
#
# See scripts/preprovision.ps1 for the canonical docs. This is the posix port.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd)"
AZURE_YAML="${REPO_ROOT}/azure.yaml"

# ── helpers ─────────────────────────────────────────────────────────────────

# pick_choice TITLE DEFAULT_VALUE -- prints picked value to stdout. Reads
# options from numbered lines fed on stdin in the form "value<TAB>display".
pick_choice() {
  local title="$1" default="$2"
  local -a values displays
  while IFS=$'\t' read -r v d; do
    values+=("$v")
    displays+=("$d")
  done

  echo "" >&2
  echo "$title" >&2
  local i marker
  for ((i=0; i<${#values[@]}; i++)); do
    marker=""
    if [[ -n "$default" && "${values[$i]}" == "$default" ]]; then
      marker="  (default)"
    fi
    printf "  [%2d] %s%s\n" "$((i+1))" "${displays[$i]}" "$marker" >&2
  done

  while true; do
    local hint=""
    if [[ -n "$default" ]]; then hint=" [Enter = default]"; fi
    read -r -p "Pick 1-${#values[@]}${hint}: " resp
    if [[ -z "$resp" ]]; then
      if [[ -n "$default" ]]; then
        echo "$default"
        return
      fi
      echo "No default available — please pick a number." >&2
      continue
    fi
    if [[ "$resp" =~ ^[0-9]+$ ]]; then
      local idx=$((resp - 1))
      if (( idx >= 0 && idx < ${#values[@]} )); then
        echo "${values[$idx]}"
        return
      fi
    fi
    for v in "${values[@]}"; do
      if [[ "$v" == "$resp" ]]; then
        echo "$resp"
        return
      fi
    done
    echo "Invalid choice. Try again." >&2
  done
}

read_with_default() {
  local prompt="$1" default="$2" resp
  read -r -p "${prompt} [${default}]: " resp
  echo "${resp:-$default}"
}

azd_env_get() {
  azd env get-value "$1" 2>/dev/null || true
}

# ── 1. Subscription ─────────────────────────────────────────────────────────

current_sub_env="$(azd_env_get AZURE_SUBSCRIPTION_ID)"
if [[ -z "$current_sub_env" ]]; then
  echo "Fetching subscriptions you have access to..." >&2
  subs_tsv="$(az account list --query "[?state=='Enabled'].[id,name]" -o tsv 2>/dev/null || true)"
  if [[ -z "$subs_tsv" ]]; then
    echo "ERROR: No enabled subscriptions found. Run 'az login' and try again." >&2
    exit 1
  fi
  default_sub="$(az account show --query id -o tsv 2>/dev/null || true)"
  picked="$(
    while IFS=$'\t' read -r sub_id sub_name; do
      printf "%s\t%-40s  %s\n" "$sub_id" "$sub_name" "$sub_id"
    done <<<"$subs_tsv" | pick_choice 'Select an Azure subscription' "$default_sub"
  )"
  azd env set AZURE_SUBSCRIPTION_ID "$picked" >/dev/null
  az account set --subscription "$picked" 2>/dev/null || true
  echo "AZURE_SUBSCRIPTION_ID = $picked"
else
  echo "AZURE_SUBSCRIPTION_ID already set: $current_sub_env"
fi

# ── 2. Region ───────────────────────────────────────────────────────────────

current_loc="$(azd_env_get AZURE_LOCATION)"
if [[ -z "$current_loc" ]]; then
  regions=(
    eastus2 eastus westus2 westus3 westus southcentralus northcentralus
    canadacentral canadaeast brazilsouth francecentral germanywestcentral
    italynorth spaincentral swedencentral switzerlandnorth norwayeast
    polandcentral uksouth westeurope uaenorth southafricanorth
    japaneast koreacentral southeastasia southindia australiaeast
  )
  picked="$(
    for r in "${regions[@]}"; do
      printf "%s\t%s\n" "$r" "$r"
    done | pick_choice 'Select an Azure region' 'eastus2'
  )"
  azd env set AZURE_LOCATION "$picked" >/dev/null
  echo "AZURE_LOCATION = $picked"
else
  echo "AZURE_LOCATION already set: $current_loc"
fi

# ── 3. Resource naming ──────────────────────────────────────────────────────

sanitize_prefix() {
  local raw="$1"
  local clean
  clean="$(echo "$raw" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
  if [[ ${#clean} -gt 16 ]]; then clean="${clean:0:16}"; fi
  echo "$clean"
}

current_prefix="$(azd_env_get AZURE_NAME_PREFIX)"
if [[ -z "$current_prefix" ]]; then
  echo ""
  echo "Resource naming"
  echo "(Used as the default base name for every resource.)"

  default_prefix="$(azd_env_get AZURE_ENV_NAME)"
  if [[ -z "$default_prefix" ]]; then default_prefix='soc-agent'; fi
  name_prefix="$(read_with_default 'Name prefix' "$default_prefix")"
  name_prefix="${name_prefix%-}"
  azd env set AZURE_NAME_PREFIX "$name_prefix" >/dev/null

  sanitized="$(sanitize_prefix "$name_prefix")"

  declare -A defaults
  defaults[AZURE_RESOURCE_GROUP]="rg-${name_prefix}"
  defaults[AZURE_VNET_NAME]="${name_prefix}-vnet"
  defaults[AZURE_AI_ACCOUNT_NAME]="${name_prefix}-foundry"
  defaults[AZURE_AI_PROJECT_NAME]="${name_prefix}-project"
  defaults[AZURE_COSMOS_DB_NAME]="${name_prefix}-cosmos"
  defaults[AZURE_AI_SEARCH_NAME]="${name_prefix}-search"
  defaults[AZURE_STORAGE_NAME]="${sanitized}stor"
  defaults[AZURE_ACR_NAME]="${sanitized}acr"

  echo ""
  echo "Derived resource names (Enter accepts; type to override):"
  for key in AZURE_RESOURCE_GROUP AZURE_VNET_NAME AZURE_AI_ACCOUNT_NAME \
             AZURE_AI_PROJECT_NAME AZURE_COSMOS_DB_NAME AZURE_AI_SEARCH_NAME \
             AZURE_STORAGE_NAME AZURE_ACR_NAME; do
    existing="$(azd_env_get "$key")"
    default="${existing:-${defaults[$key]}}"
    value="$(read_with_default "  $key" "$default")"
    azd env set "$key" "$value" >/dev/null
  done
  echo "Resource names saved."
else
  echo "AZURE_NAME_PREFIX already set: $current_prefix"
fi

# ── 4. Foundry model deployment ─────────────────────────────────────────────

current_model="$(azd_env_get AZURE_AI_MODEL_DEPLOYMENT_NAME)"
if [[ -z "$current_model" ]]; then
  echo ""
  echo "Foundry model deployment (Enter accepts the default in brackets):"
  model_name="$(read_with_default 'Model name'           'gpt-5.4')"
  model_version="$(read_with_default 'Model version'     '2026-03-05')"
  model_format="$(read_with_default 'Model format'       'OpenAI')"
  model_sku="$(read_with_default 'Model SKU'             'GlobalStandard')"
  model_capacity="$(read_with_default 'Model capacity (TPM)' '500')"

  if ! [[ "$model_capacity" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Model capacity must be an integer (got: '$model_capacity')." >&2
    exit 1
  fi

  azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME "$model_name"     >/dev/null
  azd env set MODEL_VERSION                  "$model_version"  >/dev/null
  azd env set MODEL_FORMAT                   "$model_format"   >/dev/null
  azd env set MODEL_SKU                      "$model_sku"      >/dev/null
  azd env set MODEL_CAPACITY                 "$model_capacity" >/dev/null

  # Patch the SOC_AGENT_MODEL_DEPLOYMENT block in azure.yaml using Python.
  MODEL_FORMAT="$model_format" MODEL_NAME="$model_name" \
  MODEL_VERSION="$model_version" MODEL_SKU="$model_sku" \
  MODEL_CAPACITY="$model_capacity" AZURE_YAML="$AZURE_YAML" \
  python3 - <<'PYEOF'
import os, re, sys
path = os.environ['AZURE_YAML']
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()
new_block = (
    "        # >>> SOC_AGENT_MODEL_DEPLOYMENT — managed by scripts/preprovision (do not edit manually) >>>\n"
    "        - model:\n"
    f"            format: {os.environ['MODEL_FORMAT']}\n"
    f"            name: {os.environ['MODEL_NAME']}\n"
    f'            version: "{os.environ["MODEL_VERSION"]}"\n'
    f"          name: {os.environ['MODEL_NAME']}\n"
    "          sku:\n"
    f"            capacity: {os.environ['MODEL_CAPACITY']}\n"
    f"            name: {os.environ['MODEL_SKU']}\n"
    "        # <<< SOC_AGENT_MODEL_DEPLOYMENT <<<"
)
pattern = re.compile(r'(?ms)[ \t]*# >>> SOC_AGENT_MODEL_DEPLOYMENT.*?# <<< SOC_AGENT_MODEL_DEPLOYMENT <<<')
if not pattern.search(content):
    print("warning: SOC_AGENT_MODEL_DEPLOYMENT markers not found; azure.yaml unchanged", file=sys.stderr)
    sys.exit(0)
new = pattern.sub(new_block, content)
with open(path, 'w', encoding='utf-8') as f:
    f.write(new)
PYEOF

  echo "Model deployment set: $model_name ($model_format $model_version, $model_capacity TPM)"
  echo "(azure.yaml deployments block has been updated with your selection.)"
else
  echo "Model deployment already set: $current_model"
fi

# ── 5. Capability-host idempotency ──────────────────────────────────────────
#
# The Foundry project's connections (Cosmos / Storage / AI Search) become
# locked once the project capability host is created ("Connection is in use by
# the workspace capability host and cannot be modified or deleted"). Re-running
# 'azd provision' would then fail trying to re-apply those connections.
#
# Probe whether the capability host already exists and surface the result as
# AZURE_CAPABILITY_HOST_EXISTS. When true, the Bicep skips re-applying the
# connections and the capability host. On a first deploy the probe returns
# false and everything is created.

cap_host_name='caphostproj'   # must match projectCapHost in resources.bicep
sub_id="$(azd_env_get AZURE_SUBSCRIPTION_ID)"
rg_name="$(azd_env_get AZURE_RESOURCE_GROUP)"
acct_name="$(azd_env_get AZURE_AI_ACCOUNT_NAME)"
proj_name="$(azd_env_get AZURE_AI_PROJECT_NAME)"

cap_host_exists='false'
if [[ -n "$sub_id" && -n "$rg_name" && -n "$acct_name" && -n "$proj_name" ]]; then
  cap_host_url="https://management.azure.com/subscriptions/${sub_id}/resourceGroups/${rg_name}/providers/Microsoft.CognitiveServices/accounts/${acct_name}/projects/${proj_name}/capabilityHosts/${cap_host_name}?api-version=2025-04-01-preview"
  state="$(az rest --method get --url "$cap_host_url" --query "properties.provisioningState" -o tsv 2>/dev/null || true)"
  if [[ "$state" == "Succeeded" ]]; then
    cap_host_exists='true'
  fi
fi

azd env set AZURE_CAPABILITY_HOST_EXISTS "$cap_host_exists" >/dev/null
if [[ "$cap_host_exists" == "true" ]]; then
  echo "Capability host '$cap_host_name' already exists — skipping connection/caphost re-apply (AZURE_CAPABILITY_HOST_EXISTS=true)."
else
  echo "Capability host not found — connections and caphost will be created (AZURE_CAPABILITY_HOST_EXISTS=false)."
fi

# ── 6. Reset a failed Container Apps environment ────────────────────────────
#
# A managed environment stuck in 'Failed' (e.g. from a transient
# ManagedEnvironmentCapacityHeavyUsageError) cannot host a Container App and
# does not self-repair — re-running 'azd provision' then fails with
# ManagedEnvironmentNotReadyForAppCreation. Delete any failed MCP environment
# so the next provision recreates it cleanly. Healthy ('Succeeded')
# environments are left untouched.

if [[ -n "$sub_id" && -n "$rg_name" ]]; then
  env_list_url="https://management.azure.com/subscriptions/${sub_id}/resourceGroups/${rg_name}/providers/Microsoft.App/managedEnvironments?api-version=2024-03-01"
  failed_env_ids="$(az rest --method get --url "$env_list_url" --query "value[?starts_with(name, 'cae-mcp-') && properties.provisioningState=='Failed'].id" -o tsv 2>/dev/null || true)"
  if [[ -n "$failed_env_ids" ]]; then
    while IFS= read -r env_id; do
      [[ -z "$env_id" ]] && continue
      env_name="${env_id##*/}"
      env_url="https://management.azure.com${env_id}?api-version=2024-03-01"
      echo "Container Apps environment '$env_name' is in 'Failed' state — deleting so it can be recreated..."
      # NOTE: use a direct REST DELETE, not 'az resource delete' — the generic
      # command fails to delete managed environments. Deletion is async, so poll
      # until the resource is gone; otherwise the subsequent provision collides
      # with the still-deleting environment (same name).
      az rest --method delete --url "$env_url" >/dev/null 2>&1 || true
      deleted="false"
      for _ in $(seq 1 60); do
        sleep 15
        if ! az rest --method get --url "$env_url" >/dev/null 2>&1; then
          deleted="true"; break
        fi
      done
      if [[ "$deleted" == "true" ]]; then
        echo "Deleted failed environment '$env_name'."
      else
        echo "Environment '$env_name' is still deleting after several minutes; if provision fails, wait a minute and re-run 'azd provision'."
      fi
    done <<< "$failed_env_ids"
  fi
fi
