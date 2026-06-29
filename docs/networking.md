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

## Pushing images to the private ACR

`azd deploy` builds the agent and MCP-server Docker images and pushes them to
the private ACR. Because ACR is created with `publicNetworkAccess: Disabled`,
the push only succeeds from a host that can reach the ACR private endpoint.

### Recommended: run `azd deploy` from inside the VNet

A small Linux VM (or Bastion-accessible Windows jump host) inside the VNet —
or inside a VNet peered to it with the `privatelink.azurecr.io` private DNS
zone linked — is the cleanest and most production-friendly path.

Requirements on the in-VNet host:

- DNS for `<acr>.azurecr.io` resolves to the **private** IP from the PE subnet.
  Verify with `nslookup <acr>.azurecr.io`.
- An identity with `AcrPush` on the registry. Three common shapes:
  - Interactive `az login` as a user with `AcrPush`.
  - VM system-assigned managed identity granted `AcrPush`, then
    `az login --identity`.
  - Service principal credentials.
- `azd`, `az`, and Docker installed.

Two flows are supported:

| Flow | Where you run what | When to use |
|---|---|---|
| **Split** | `azd provision` from anywhere, then `azd deploy` from the in-VNet host (after `azd env refresh`). | Bootstrapping from a laptop, then handing off image builds to a build VM / CI runner. |
| **Single shot** | `azd up` from the in-VNet host. | Your dev environment already lives inside the VNet. |

### Alternative: dev-only IP allowlist on ACR

Setting `DEVELOPER_IP_CIDR` flips ACR to `publicNetworkAccess: Enabled` with a
**default-deny firewall and a single allow rule** for that CIDR. Pushes from
that IP succeed; everything else is still blocked.

```powershell
azd env set DEVELOPER_IP_CIDR "$(curl -s https://api.ipify.org)/32"
azd provision    # re-applies the ACR network ACL with the allowlist
azd deploy
```

Use this for one-off dev or demos only. Clear it when done:

```powershell
azd env set DEVELOPER_IP_CIDR ""
azd provision
```

Caveats:
- Your public IP rotates on roaming networks (cellular, café Wi-Fi, some
  corporate VPNs) — you'll need to re-set the CIDR and re-provision.
- Behind a corporate NAT you may need a wider CIDR (e.g. `/26`); coordinate
  with networking.
- Don't use this in production — it widens the attack surface.

### What about ACR Tasks (server-side builds)?

Adding `docker.remoteBuild: true` to the `mcp-http-server` service in
`azure.yaml` would tell `azd` to use ACR Tasks instead of local Docker.
**However**, classic ACR Tasks build agents run on Microsoft-managed shared
infrastructure that lives **outside your VNet** and cannot push to an ACR
with `publicNetworkAccess: Disabled`. To make ACR Tasks work with a private
registry you'd need a **dedicated agent pool inside the VNet**
(`az acr agentpool create --subnet ...`) and wire `--agent-pool` into the
build call via an `azd` hook. This is intentionally not part of the starter
template — adopt it later if you need fully server-side builds.

> The `copilot-agent` service is different: it uses
> `host: azure.ai.agent` + `docker.remoteBuild: true`, which means the
> Foundry platform itself builds the image inside Azure infrastructure that
> has direct connectivity to the project's ACR. That service deploys fine
> from outside the VNet — only the `mcp-http-server` service needs an
> in-VNet (or allowlisted) push path.
