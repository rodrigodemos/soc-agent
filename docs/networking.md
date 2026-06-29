# Networking

## Subnet sizing

| Subnet | Default prefix | Min recommended size | Notes |
|--------|----------------|----------------------|-------|
| Agent  | `192.168.0.0/24` | `/24` | **Must** be exclusively delegated to `Microsoft.App/environments`. Cannot be shared with another Foundry account. |
| PE     | `192.168.1.0/24` | `/27` | Holds private endpoints for Foundry, Cosmos, Search, Storage, ACR, AMPLS. |
| MCP    | `192.168.2.0/24` | `/27` | Holds the MCP HTTP server Container App (and future A2A / Functions tools). |

## Address space

Allowed VNet IP ranges: any RFC 1918 (`10.0.0.0/8`, `172.16.0.0/12`,
`192.168.0.0/16`). Class A (`10.x.x.x`) ranges are supported in most regions
but not all — see the upstream
[`sample 19` README](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/19-private-network-agent-tools)
for the current region list. Use Class B or C for unsupported regions.

Avoid these reserved ranges:
`169.254.0.0/16`, `172.30.0.0/16`, `172.31.0.0/16`, `192.0.2.0/24`,
`0.0.0.0/8`, `127.0.0.0/8`, `100.100.0.0/17`, `100.100.192.0/19`,
`100.100.224.0/19`, `100.64.0.0/11`.

## Private DNS zones

The template creates (or references, when BYO) these zones and links them to
the VNet:

- `privatelink.services.ai.azure.com`
- `privatelink.openai.azure.com`
- `privatelink.cognitiveservices.azure.com`
- `privatelink.search.windows.net`
- `privatelink.blob.<storage-suffix>` (e.g. `privatelink.blob.core.windows.net`)
- `privatelink.documents.azure.com`
- `privatelink.azurecr.io`

Plus the Azure Monitor Private Link Scope zones for trace ingestion:

- `privatelink.monitor.azure.com`
- `privatelink.oms.opinsights.azure.com`
- `privatelink.ods.opinsights.azure.com`
- `privatelink.agentsvc.azure-automation.net`

If your enterprise uses a hub-and-spoke landing zone with centralized DNS,
pass the existing zones via the `existingDnsZones` / `existingMonitorDnsZones`
parameters. Format:

```jsonc
{
  "privatelink.azurecr.io": {
    "subscriptionId": "<sub of the central DNS RG>",
    "resourceGroup":  "<name of the central DNS RG>"
  },
  // …
}
```

> When you reference an existing zone, **the template does not create a VNet
> link** to it. Ensure your hub VNet is already linked, or peer your spoke
> VNet to it.

## Egress

Outbound traffic from the Agent and MCP subnets goes through the standard
ACA-environment egress (Microsoft-managed NAT). If your enterprise requires
**force-tunneling** through a hub firewall, set up a UDR on the relevant
subnet and route `0.0.0.0/0` to the firewall.

The Copilot SDK in `src/copilot-agent` does **not** reach out to `github.com`
in this template (the `GITHUB_TOKEN` code path has been removed) — it only
talks to the Foundry project endpoint over the VNet's data proxy.

## ACR push from a developer workstation

When you run `azd deploy` from a workstation outside the VNet, the developer
machine needs to push images to the private ACR. The template supports this
via a per-environment IP allowlist:

```powershell
azd env set DEVELOPER_IP_CIDR "$(curl -s https://api.ipify.org)/32"
azd provision    # re-applies the ACR network ACL
azd deploy
```

When `DEVELOPER_IP_CIDR` is empty (production), ACR `publicNetworkAccess` is
`Disabled` and pushes must go over the VNet (e.g., via Bastion or a self-hosted
agent inside the VNet).
