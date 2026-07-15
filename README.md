# soc-agent

A **starter template** for a Microsoft Foundry **hosted agent** that runs the
**GitHub Copilot SDK** on a **fully private VNet**, deployed end-to-end with
`azd up`.

This repo combines two upstream projects into a single deployable solution:

- **`rodrigodemos/foundry-ghcp-hosted`** — an `azd`-managed Foundry hosted agent
  using the Copilot SDK over the `azure-ai-agentserver-invocations` protocol,
  with BYOK Foundry-model auth via Managed Identity.
- **`microsoft-foundry/foundry-samples/.../19-private-network-agent-tools`** —
  the Bicep templates for a network-secured Foundry account, BYO backend
  resources (Cosmos DB / AI Search / Storage) on private endpoints, BYO VNet
  (Agent / PE / MCP subnets), Premium ACR with private endpoint, Application
  Insights with Azure Monitor Private Link Scope (AMPLS), and tools behind the
  VNet (a sample MCP HTTP server).

> Light SOC theming only (agent display name and system prompt). The repo is
> **customer-agnostic** — all customer-specific data sources, MCP servers,
> cookbooks, and eval sets live in [`docs/BACKLOG.md`](docs/BACKLOG.md) as
> future-phase work.

## Architecture (one paragraph)

`azd up` provisions: a private VNet with three subnets (Agent — delegated to
`Microsoft.App/environments`; PE — for private endpoints; MCP — for
user-deployed Container Apps), a Foundry account with `publicNetworkAccess:
Disabled` and a project that connects to BYO Cosmos DB / AI Search / Storage
over private endpoints, a Premium ACR with a private endpoint, Application
Insights with private ingestion via AMPLS, an Azure-managed capability host on
the Foundry project (no bash script needed), and a sample MCP HTTP server
Container App on the MCP subnet. `azd deploy` then builds and ships the
Copilot-SDK agent image (`src/copilot-agent`) and the MCP HTTP server image
(`src/mcp-http-server`) to the private ACR.

See [`docs/architecture.md`](docs/architecture.md) and
[`docs/networking.md`](docs/networking.md) for the full picture.

## Prerequisites

1. Azure subscription with permission to:
   - Create the Foundry account and project (Foundry Account Owner)
   - Assign RBAC (Owner or Role-Based Access Administrator)
   - Register the resource providers below
2. Required RPs (one-time per subscription):
   ```bash
   az provider register --namespace Microsoft.KeyVault
   az provider register --namespace Microsoft.CognitiveServices
   az provider register --namespace Microsoft.Storage
   az provider register --namespace Microsoft.Search
   az provider register --namespace Microsoft.Network
   az provider register --namespace Microsoft.App
   az provider register --namespace Microsoft.ContainerService
   az provider register --namespace Microsoft.OperationalInsights
   az provider register --namespace Microsoft.Insights
   ```
3. **Quota and regional capacity** for the model SKU and the BYO backends.
   Defaults: `gpt-5.4` `GlobalStandard` cap 500 (adjust via
   `AZURE_AI_MODEL_DEPLOYMENT_NAME`, `MODEL_VERSION`, `MODEL_SKU`,
   `MODEL_CAPACITY`).
   > **Heads-up:** `eastus2` / `eastus` / `westus2` are consistently the most
   > loaded Foundry regions and frequently return
   > `InsufficientResourcesAvailable` mid-deploy. `westus3`,
   > `swedencentral`, and `australiaeast` have more headroom. See
   > [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) for the full
   > error-and-remediation list.
4. Tooling:
   - [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) ≥ 2.60
   - [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) ≥ 1.10
   - Docker — required on the host that runs `azd deploy` (the MCP HTTP
     server image is built locally). Not needed on a host that only runs
     `azd provision`.
5. **Where you run `azd deploy` from** — see [Deployment paths](#deployment-paths) below. Either:
   - **In-VNet host** (recommended) — a VM inside the VNet, or one in a peered
     VNet linked to the `privatelink.azurecr.io` private DNS zone, **or**
   - **Any laptop, with a one-off ACR IP allowlist** for that workstation.

## Getting started

Three steps from a fresh clone to a running agent — all run from a VM inside the target VNet (or one in a peered VNet with the `privatelink.azurecr.io` DNS zone linked). Don't have an in-VNet host? See [Deployment paths](#deployment-paths) below for the split flow.

### 1. Clone and sign in

```powershell
git clone <this-repo> soc-agent
cd soc-agent
azd auth login
azd init --environment soc-agent-dev      # any env name you want
```

### 2. Validate prerequisites

```powershell
.\scripts\check-prereqs.ps1               # add -RegisterProviders for any missing RPs
```

A clean run ends with `Passed: NN, Warnings: 0, Failures: 0`.

### 3. Provision and deploy

```powershell
azd up
```

The template's preprovision hook will interactively prompt for:

- **Azure subscription** (numbered picker; default = your current `az` context)
- **Azure region** (numbered picker)
- **Resource naming** — a single `AZURE_NAME_PREFIX` (default = your azd env name) drives every resource name (Foundry account, project, Cosmos DB, AI Search, storage, ACR, VNet, RG); each is shown for review and can be overridden one by one
- **Foundry model** — name (default `gpt-5.4`), version, format, SKU, capacity (TPM)

After `azd up` finishes (~25–35 min on first run), open the **Foundry portal** → your project → **Agents** → invoke `soc-copilot-agent` from the Playground.

> **Need help?** [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) covers
> common failures (regional capacity, capability-host validation, subnet
> reuse after delete, etc.). For unattended/CI runs, pinning env vars
> ahead of time, BYO networking, BYO backends, and the split-deploy
> workflow, see the sections below.

## Deployment paths

Because the Azure Container Registry is provisioned with **public network access disabled**, the `docker push` step in `azd deploy` only succeeds from a host that can reach the ACR private endpoint. The provision step is unaffected — Azure Resource Manager is always public.

That gives you two supported workflows:

### Path A — `azd up` from an in-VNet host (recommended)

This is what the [Getting started](#getting-started) walkthrough above uses. Everything runs from a single VM inside the VNet.

### Path B — Split: `azd provision` from anywhere, `azd deploy` from in-VNet

Use this when you're bootstrapping from a laptop and don't have an in-VNet build host yet (the very first `azd provision` creates the VNet that future deploys will run from).

```powershell
# ── Step 1 — From your laptop (anywhere) ─────────────────────────────────
azd auth login
azd init --environment soc-agent-dev
.\scripts\check-prereqs.ps1
azd provision                  # creates VNet, Foundry, private endpoints, ACR, etc.
```

```bash
# ── Step 2 — From a VM / Bastion host inside the VNet (or a peered VNet) ─
git clone <this-repo>
cd soc-agent
azd auth login                 # or: az login --identity (VM SMI granted AcrPush)
azd env refresh --environment soc-agent-dev   # pulls the env values from Azure
azd deploy                     # builds + pushes images, updates the agent + ACA app
```

What the in-VNet host needs:
- DNS for `<acr>.azurecr.io` resolves to the **private IP** in the PE subnet.
- An identity with `AcrPush` on the registry (interactive user, managed identity, or SP).
- `azd`, `az`, and Docker installed.

### Unattended / CI runs

If you want to bypass the interactive preprovision prompts (e.g., in a pipeline), set the env vars ahead of time:

```powershell
azd env set AZURE_SUBSCRIPTION_ID (az account show --query id -o tsv)
azd env set AZURE_LOCATION eastus2
azd env set AZURE_NAME_PREFIX soc-agent-dev
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME gpt-5.4
azd env set MODEL_VERSION 2026-03-05
azd env set MODEL_SKU GlobalStandard
azd env set MODEL_CAPACITY 500
```

The hook detects which vars are already set and skips just those prompts. To re-prompt for any one of them later, clear it:

```powershell
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME ""   # hook will re-prompt the model
azd provision
```

### Alternative: dev-only IP allowlist on ACR

For one-off dev or demos where standing up an in-VNet build host is overkill, you can temporarily open the ACR firewall to your workstation's public IP. Set `DEVELOPER_IP_CIDR` **before** `azd provision` and `azd deploy` will be able to push from your laptop:

```powershell
azd env set DEVELOPER_IP_CIDR "$(curl -s https://api.ipify.org)/32"
azd up
```

When set, `infra/modules/registry/container-registry.bicep` flips ACR to `publicNetworkAccess: Enabled` with a **default-deny firewall plus a single allow rule for that CIDR**. Don't use this in production — clear it (`azd env set DEVELOPER_IP_CIDR ""` then `azd provision`) when you're done. See [`docs/networking.md`](docs/networking.md) for the trade-offs and notes on ACR Tasks with private registries.

### Switching between private and public Foundry access

The Foundry account is created with `publicNetworkAccess: Disabled` and
`defaultAction: Deny`. To flip it to public during dev:

```bash
# in infra/modules/ai/ai-account-identity.bicep
# change:  publicNetworkAccess: 'Disabled'  →  'Enabled'
# change:  defaultAction: 'Deny'            →  'Allow'
azd provision
```

Backend resources (Cosmos / Search / Storage / ACR / AppInsights) remain on
private endpoints in both modes.

### Using an existing VNet (BYO)

Set the following before `azd up`:

```powershell
azd env set EXISTING_VNET_RESOURCE_ID         "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>"
azd env set EXISTING_AGENT_SUBNET_RESOURCE_ID "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<agent-subnet>"
azd env set EXISTING_PE_SUBNET_RESOURCE_ID    "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<pe-subnet>"
azd env set EXISTING_MCP_SUBNET_RESOURCE_ID   "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<mcp-subnet>"
```

The agent subnet **must** be exclusively delegated to
`Microsoft.App/environments` and unused by any other resource. See
[`docs/networking.md`](docs/networking.md) for sizing guidance.

### Using existing backend resources

Set any of these to reuse existing Cosmos DB / AI Search / Storage accounts:

```powershell
azd env set EXISTING_AZURE_COSMOS_DB_ACCOUNT_RESOURCE_ID "<ARM ID>"
azd env set EXISTING_AI_SEARCH_RESOURCE_ID               "<ARM ID>"
azd env set EXISTING_AZURE_STORAGE_ACCOUNT_RESOURCE_ID   "<ARM ID>"
```

## Repository layout

```
.
├── README.md                       # this file
├── azure.yaml                      # azd manifest (services: copilot-agent, mcp-http-server)
├── infra/                          # Bicep IaC (default)
│   ├── main.bicep                  # subscription-scoped: RG + workload
│   ├── resources.bicep             # RG-scoped: ported sample 19 main + MCP tool
│   ├── main.parameters.json        # azd env-var bindings
│   ├── abbreviations.json
│   └── modules/
│       ├── network/                # VNet + subnets (new or BYO)
│       ├── ai/                     # Foundry account, project, cap host
│       ├── dependencies/           # BYO Cosmos / Search / Storage
│       ├── privatelink/            # private endpoints + DNS zones + AMPLS
│       ├── monitoring/             # workspace-based Application Insights
│       ├── registry/               # Premium ACR + PE + dev-IP allowlist
│       ├── roles/                  # RBAC assignments (storage, cosmos, search)
│       └── tools/                  # ACA env + MCP HTTP server app
├── infra-terraform/                # Terraform IaC (alternative — see README inside)
│   ├── main.tf                     # all resources
│   ├── variables.tf, locals.tf, data.tf, outputs.tf, providers.tf, versions.tf
│   ├── main.tfvars.json            # azd env-var bindings
│   ├── example.tfvars              # sample vars for standalone `terraform apply`
│   └── README.md                   # how to switch and standalone-use guide
├── src/
│   ├── copilot-agent/              # Foundry hosted agent (Copilot SDK, BYOK)
│   └── mcp-http-server/            # Sample MCP HTTP server (FastMCP)
├── scripts/
│   ├── check-prereqs.ps1           # pre-flight validation
│   ├── preprovision.ps1/.sh        # azd hook — pickers + naming + model prompts
│   ├── createCapHost.sh / deleteCapHost.sh   # cap-host escape hatches
│   └── get-existing-resources.ps1  # BYO helper
└── docs/
    ├── architecture.md
    ├── networking.md
    ├── TROUBLESHOOTING.md
    └── BACKLOG.md
```

### Bicep vs Terraform

Both stacks are feature-equivalent and share the same azd env vars and output
names. Pick one:

- **Bicep (default)** — `infra/`, referenced from `azure.yaml` out of the box.
- **Terraform** — `infra-terraform/`, switch by changing `infra.provider` and
  `infra.path` in `azure.yaml`. See [`infra-terraform/README.md`](infra-terraform/README.md).

The preprovision hook, `check-prereqs.ps1`, and everything under `src/`
work identically with either provider.

## Troubleshooting

Common deploy failures (regional capacity, capability-host issues,
soft-deleted account purge, etc.) and their fixes are documented in
[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

## Cleanup

```powershell
azd down --purge --force
```

`--purge` matters: the Foundry account is soft-deleted by default, and the
capability host blocks re-use of the agent subnet until the account is purged.
Allow up to ~20 minutes for full cleanup. The `scripts/deleteCapHost.sh`
script is provided as an escape hatch if you want to delete the capability
host without deleting the account.

## What's *not* in this template (yet)

Phase 2+ features live in [`docs/BACKLOG.md`](docs/BACKLOG.md): additional MCP
servers (e.g. Sentinel, ServiceNow), A2A agent, Azure Functions MCP, federated
search tool contract, cookbook catalog, eval framework, MCP hosting bake-off
(Functions vs Logic Apps vs APIM), multi-environment promotion, KQL generation
tool.

## License

This template is provided as-is. Upstream components retain their original
licenses:
- `microsoft-foundry/foundry-samples` is MIT-licensed.
- `github/copilot-sdk` and `azure-ai-agentserver-invocations` retain their
  respective licenses.
