# Troubleshooting

Known issues hit by this template's deployments, with concrete remediation.

## `azd provision` failures

### `InsufficientResourcesAvailable: The region '<region>' is currently out of the resources required to provision new services`

**Symptom (during `aiDependencies` deployment):**
```
"code": "InsufficientResourcesAvailable",
"message": "The region 'eastus2' is currently out of the resources required to
provision new services. Try creating the service in another region."
```

**Cause.** Azure regional capacity has hit a ceiling for one of the BYO backend
services (Cosmos DB, AI Search, or Storage). This is an Azure-side condition,
not a template bug. `eastus2` is the most loaded Foundry region most days.

**Fix.** Switch region.

```powershell
azd down --purge --force                # clean up the failed RG
azd env set AZURE_LOCATION ""           # clear the saved region
azd provision                           # hook re-prompts; pick a less-loaded region
```

Regions that consistently have headroom (rough ordering):

1. `westus3`
2. `swedencentral`
3. `australiaeast`
4. `canadaeast`
5. `germanywestcentral`

If you can't switch regions, request a capacity quota increase for the
specific service via Azure Portal → Subscriptions → your sub → Usage + quotas
→ filter by the service that failed.

### `Capability host creation failed ... Invalid vnet resource ID provided, or the virtual network could not be found`

**Symptom (during AI account creation):**
```
"code": "ResourceProviderExtensionError",
"message": "ExtendedErrorInfo:: Kind: AmlRp, Code: BadRequest,
Message: Capability host creation failed with agent messages:
{... "Invalid vnet resource ID provided, or the virtual network could not be found." ...}"
```

**Cause.** When the AI Services account is created with
`networkInjections.useMicrosoftManagedNetwork = false`, Azure spawns an
auto-capability-host that validates the agent subnet from the AML AI Agent
Service control plane. This validation has two known failure modes:

1. **Cascading from a regional-capacity failure** elsewhere in the same
   deployment (most common — if `aiDependencies` fails for capacity, this
   error usually surfaces in parallel even though the VNet is fine).
2. **Eventual-consistency lag** between `Microsoft.Network` finishing the
   VNet/subnets and the AML AI Agent Service's view of them.

**Fix — try in order:**

1. **Confirm it's not capacity.** Check if `aiDependencies` also failed in
   the same deployment. If yes, fix the region (see previous section) and
   this will likely resolve too.
2. **Clean up and retry.** Soft-deleted Foundry accounts hold the agent
   subnet hostage; you must **purge** before re-deploying.
   ```powershell
   azd down --purge --force
   # If azd down leaves things behind:
   az group delete --name rg-<env-name> --yes --no-wait
   az cognitiveservices account list-deleted --query "[?contains(name,'aifoundry')]" -o table
   az cognitiveservices account purge --location <region> --resource-group rg-<env-name> --name <account-name>
   ```
3. **If it persists in a fresh region**, use the manual capability-host
   fallback shipped in this template:
   ```powershell
   # After azd provision completes (and the account is created but caphost failed),
   # set the account-level caphost via the upstream script:
   bash scripts/createCapHost.sh <subscription-id> <resource-group> <account-name> <project-name>
   ```

### `Subnet already in use` / `agent subnet must be exclusively used by a single Foundry account`

**Cause.** A previous Foundry account was deleted but **not purged**. The
deleted account still holds the delegation on the agent subnet for ~20 min
(or indefinitely if not purged).

**Fix.** Purge the soft-deleted account (commands in the previous section).
Wait ~10–20 min after purge for the subnet to be released, then redeploy.

### `AZURE_SUBSCRIPTION_ID is required`

**Cause.** The `azure.ai.agents` extension's preflight runs before azd's
own subscription prompt. Should be handled by `scripts/preprovision.ps1`
in this template — if you see it, the hook didn't run.

**Fix.**
```powershell
azd env set AZURE_SUBSCRIPTION_ID (az account show --query id -o tsv)
azd provision
```

### `failed to parse foundry agent config: json: cannot unmarshal string into ... type int`

**Cause.** Someone re-introduced `${VAR=default}` substitution into the
`deployments:` block of `azure.yaml`. azd's substitution always emits
strings; the `capacity` field is typed as int.

**Fix.** Inside the `# >>> SOC_AGENT_MODEL_DEPLOYMENT >>>` markers,
all values must be literal YAML (string or int). The preprovision hook
regenerates this block from typed env vars.

## `azd deploy` failures

### `docker push` denied / cannot reach registry

**Cause.** You're running `azd deploy` from outside the VNet against an
ACR with `publicNetworkAccess: Disabled`.

**Fix.** Either run `azd deploy` from an in-VNet host (recommended; see
[`docs/networking.md`](networking.md)), or set `DEVELOPER_IP_CIDR` to your
public IP CIDR and re-run `azd provision`, then `azd deploy`.

## Foundry Playground / agent invocation

### Agent shows in Playground but returns auth errors

**Cause.** The agent's managed identity hasn't propagated, or the model
deployment was provisioned in a different name than the agent is referencing.

**Fix.**
1. Wait ~5 min for managed identity propagation.
2. Confirm the model name in `agent.manifest.yaml` matches the deployment
   name in `azure.yaml`.
3. Tail traces: open Application Insights (provisioned by the template) and
   filter by the agent's invocation ID.

### Agent can't reach the MCP HTTP server

**Cause.** Container App ingress is internal-only by design — only callable
from inside the VNet.

**Fix.** The agent itself runs on the Agent subnet, so it can reach the MCP
server's internal FQDN. If you're testing manually from outside, you'll need
a VPN, Bastion, or jump VM that can resolve the ACA env's internal DNS zone.

## General debugging tips

- `azd env get-values` to see what's saved in your env.
- `azd show` to see the current azd state (provisioned resources, outputs).
- Which IaC is active: `grep -E 'provider|path' azure.yaml` — the template
  ships both `infra/terraform/` (Terraform, default) and `infra/bicep/`
  (Bicep alternative); swap them by editing `azure.yaml`'s `infra:` block.
- `az deployment group list --resource-group rg-<env-name> -o table` to
  list all ARM deployments and their states.
- `az deployment group operation list --resource-group rg-<env-name> --name <deployment-name> -o table`
  to drill into a failed deployment.
- For Foundry-specific failures, the most detailed error usually comes from:
  ```powershell
  az cognitiveservices account show --name <account> --resource-group rg-<env-name>
  ```
  …and look at `properties.provisioningState` and any `properties.statusMessage`.
- **Terraform-specific**: `terraform state list` and `terraform state show <addr>`
  inside `infra/terraform/` after a failure to see what got created before it
  broke. `terraform destroy` (rather than `azd down`) is the cleanest cleanup
  path when the Terraform stack is active — it honors the `time_sleep` +
  `purge_ai_foundry` chain that releases the agent subnet.
