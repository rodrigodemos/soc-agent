# =============================================================================
# soc-agent — Example Terraform variables (standalone use, without azd)
# =============================================================================
# Copy to terraform.tfvars and edit. When running through azd, DON'T use this
# file — azd generates its own main.tfvars.json from the azd env vars (see
# main.tfvars.json in this folder for the mapping).
#
# For a standalone terraform apply:
#   cp example.tfvars terraform.tfvars
#   terraform init
#   terraform apply
# =============================================================================

# ── REQUIRED ────────────────────────────────────────────────────────────────
environment_name = "soc-agent-dev"
location         = "swedencentral" # avoid eastus2 / eastus / westus2 (capacity)

# ── OPTIONAL — resource naming ──────────────────────────────────────────────
# Each name defaults to a value derived from environment_name / a random
# suffix. Set to override. Storage / ACR names must be lowercase alphanumeric.
# resource_group_name  = "rg-soc-agent-dev"
# vnet_name            = "soc-agent-dev-vnet"
# ai_account_name      = "soc-agent-dev-foundry"
# ai_project_name      = "soc-agent-dev-project"
# cosmos_db_name       = "soc-agent-dev-cosmos"
# ai_search_name       = "soc-agent-dev-search"
# storage_account_name = "socagentdevstor"
# acr_name             = "socagentdevacr"

# ── OPTIONAL — Foundry model deployment ─────────────────────────────────────
model_name     = "gpt-5.4"
model_version  = "2026-03-05"
model_format   = "OpenAI"
model_sku      = "GlobalStandard"
model_capacity = 500

# ── OPTIONAL — Network layout (only when creating a new VNet) ───────────────
vnet_address_space = ["192.168.0.0/16"]
# agent_subnet_prefix = "192.168.0.0/24"
# pe_subnet_prefix    = "192.168.1.0/24"
# mcp_subnet_prefix   = "192.168.2.0/24"

# ── BYO — existing resources (leave empty to create new) ────────────────────
existing_resource_group_name       = ""
existing_vnet_id                   = ""
existing_agent_subnet_id           = ""
existing_pe_subnet_id              = ""
existing_mcp_subnet_id             = ""
existing_storage_account_id        = ""
existing_cosmosdb_account_id       = ""
existing_ai_search_id              = ""
existing_dns_zones_resource_group  = ""
existing_dns_zones_subscription_id = ""

# ── ACR ─────────────────────────────────────────────────────────────────────
enable_container_registry = true
# developer_ip_cidr       = "203.0.113.0/32"   # allow push from this IP

# ── MCP HTTP server ─────────────────────────────────────────────────────────
enable_mcp_http_server    = true
mcp_http_server_image_tag = "latest"
