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
3. **Quota** for the model SKU in your target region. Defaults: `gpt-4o-mini`
   `GlobalStandard` cap 30 — adjust via `AZURE_AI_MODEL_DEPLOYMENT_NAME`,
   `MODEL_VERSION`, `MODEL_SKU`, `MODEL_CAPACITY` env vars.
4. Tooling:
   - [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) ≥ 2.60
   - [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) ≥ 1.10
   - Docker (only needed locally if `azd` cannot remote-build)

## Quickstart

```powershell
# from this repo root
azd auth login
azd init --environment soc-agent-dev

# When you're on a workstation outside the VNet, set DEVELOPER_IP_CIDR so the
# ACR firewall lets you push images. Use your public IP / range (/32 is fine).
azd env set DEVELOPER_IP_CIDR "$(curl -s https://api.ipify.org)/32"
azd env set AZURE_LOCATION eastus2

# Provision + deploy
azd up
```

After `azd up` completes:

- The Foundry **portal** is reachable from a VPN/ExpressRoute/Bastion host that
  can resolve `privatelink.services.ai.azure.com` against the private endpoint.
  From the public internet, the Foundry account is **not reachable**.
- The Copilot-SDK hosted agent is callable from the **Foundry Playground** in
  your project. It runs as a Container App on the Agent subnet.
- The sample MCP HTTP server is reachable **inside the VNet** on
  `MCP_HTTP_SERVER_FQDN:80` (see `azd env get-values`).

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
├── infra/
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
├── src/
│   ├── copilot-agent/              # Foundry hosted agent (Copilot SDK, BYOK)
│   └── mcp-http-server/            # Sample MCP HTTP server (FastMCP)
├── scripts/                        # createCapHost.sh / deleteCapHost.sh / get-existing-resources.ps1
└── docs/
    ├── architecture.md
    ├── networking.md
    └── BACKLOG.md
```

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
