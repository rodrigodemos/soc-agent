# Terraform infra for `soc-agent`

**Default IaC for this template.** The Bicep alternative lives in [`../bicep/`](../bicep/).

## Switching between Terraform and Bicep

Edit `azure.yaml` at the repo root:

```yaml
# Default (Terraform)
infra:
  provider: terraform
  path: ./infra/terraform

# Alternative (Bicep)
infra:
  provider: bicep
  path: ./infra/bicep
```

Then re-run `azd up` (or `azd provision`). The preprovision hook, azd env
vars, and outputs work identically for both providers — the only difference
is the IaC engine that ARM sees.

## Files

| File | Purpose |
|---|---|
| `versions.tf`      | Provider version pins (`azapi ~> 2.5`, `azurerm ~> 4.37`, `random`, `time`). |
| `providers.tf`     | Provider blocks. `storage_use_azuread = true` on azurerm. |
| `variables.tf`     | All input variables (naming overrides, model, BYO, ACR, MCP tool). |
| `locals.tf`        | Naming resolution, BYO flags, unified resource references, DNS zone IDs. |
| `data.tf`          | Data sources for BYO Storage / Cosmos / Search / current subscription. |
| `main.tf`          | All resources: VNet, subnets, backends, Foundry account+project+caphost, DNS zones + VNet links, private endpoints, RBAC (pre- and post-caphost), App Insights, ACR, MCP HTTP server Container App, destroy-time Foundry purge. |
| `outputs.tf`       | Outputs consumed by azd (same names as `../bicep/main.bicep`). |
| `main.tfvars.json` | Bindings from azd env vars → terraform vars. azd reads this at plan time. |
| `example.tfvars`   | Sample tfvars for standalone `terraform apply` (bypassing azd). |

## Parity with Bicep

The Terraform stack is functionally equivalent to `../bicep/main.bicep` plus
its submodules. Deliberate deltas:

- **No Azure Monitor Private Link Scope (AMPLS).** The Bicep version wires an
  AMPLS so trace ingestion reaches Application Insights over the private VNet.
  The Terraform stack creates Application Insights with `internet_ingestion_
  enabled = false` but doesn't build the AMPLS + linked-services graph. Add
  `azurerm_monitor_private_link_scope` + `azurerm_monitor_private_link_scoped_
  service` if you need it.
- **No Fabric integration.** Sample 19 (Terraform) has an optional
  `existing_fabric_workspace_id` for a Data Agent private endpoint. Not
  included here — matches the Bicep scope.
- **Deterministic naming.** All the naming overrides (`ai_account_name`,
  `cosmos_db_name`, `acr_name`, …) that the Bicep version added are present
  here too, driven by the same azd env vars via `main.tfvars.json`.

## Standalone use (no azd)

```bash
cd infra/terraform
cp example.tfvars terraform.tfvars
# edit terraform.tfvars

terraform init
terraform plan
terraform apply
```

You'll still need to build & push the agent/MCP-server images to the ACR
yourself (`azd deploy` handles that automatically when going through azd).

## Cleanup

```bash
# Through azd (recommended)
azd down --purge --force

# Or standalone
terraform destroy
```

The `azapi_resource_action.purge_ai_foundry` block deletes the soft-deleted
Cognitive Services account on destroy, which releases the agent subnet's
`serviceAssociationLink` so the subnet can be reused. `time_sleep` gives the
backend ~15 min to unwind before the DELETE fires. If you skip the terraform
destroy (e.g. delete the RG directly), see
[`../../docs/TROUBLESHOOTING.md`](../../docs/TROUBLESHOOTING.md) for the
manual purge steps.
