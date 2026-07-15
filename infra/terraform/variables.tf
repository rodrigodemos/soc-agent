########## azd-required core variables (populated automatically by azd) ##########

variable "environment_name" {
  description = "Name of the azd environment. Used as a naming base when no overrides are provided. Populated by azd from AZURE_ENV_NAME."
  type        = string
}

variable "location" {
  description = "Azure region where resources will be deployed. Populated by azd from AZURE_LOCATION."
  type        = string
}

variable "principal_id" {
  description = "Object ID of the user or SPN running azd. Populated by azd from AZURE_PRINCIPAL_ID. Reserved for future direct-access role assignments."
  type        = string
  default     = ""
}

variable "principal_type" {
  description = "Principal type of principal_id ('User' or 'ServicePrincipal'). Populated by azd from AZURE_PRINCIPAL_TYPE."
  type        = string
  default     = "User"
}

########## Resource-name overrides ##########
## When empty, each name defaults to a value derived from environment_name /
## random_string.unique. The preprovision hook typically populates these via
## AZURE_* env vars so every resource gets a stable, predictable name.

variable "resource_group_name" {
  description = "Override for the resource group name. Empty = 'rg-<environment_name>'."
  type        = string
  default     = ""
}

variable "vnet_name" {
  description = "Override for the virtual network name. Empty = '<environment_name>-vnet'."
  type        = string
  default     = ""
}

variable "ai_account_name" {
  description = "Override for the Foundry (AI Services) account name. Empty = '<ai_services_name_prefix><suffix>'."
  type        = string
  default     = ""
}

variable "ai_project_name" {
  description = "Override for the Foundry project name. Empty = '<first_project_name><suffix>'."
  type        = string
  default     = ""
}

variable "cosmos_db_name" {
  description = "Override for the Cosmos DB account name. Empty = '<ai_services_name_prefix><suffix>cosmos'."
  type        = string
  default     = ""
}

variable "ai_search_name" {
  description = "Override for the AI Search service name. Empty = '<ai_services_name_prefix><suffix>search'."
  type        = string
  default     = ""
}

variable "storage_account_name" {
  description = "Override for the Storage account name (3-24 lowercase alphanumeric). Empty = '<ai_services_name_prefix><suffix>stor'."
  type        = string
  default     = ""
}

variable "acr_name" {
  description = "Override for the Azure Container Registry name (5-50 lowercase alphanumeric, globally unique). Empty = 'acr<suffix>'."
  type        = string
  default     = ""
}

########## Foundry / model ##########

variable "ai_services_name_prefix" {
  description = "Name prefix for the Foundry account when ai_account_name is not provided."
  type        = string
  default     = "aifoundry"
}

variable "first_project_name" {
  description = "Name prefix for the Foundry project when ai_project_name is not provided."
  type        = string
  default     = "socproject"
}

variable "model_name" {
  description = "The Foundry model deployment name."
  type        = string
  default     = "gpt-5.4"
}

variable "model_version" {
  description = "The Foundry model version."
  type        = string
  default     = "2026-03-05"
}

variable "model_format" {
  description = "The Foundry model provider/family (e.g. OpenAI, Meta, Microsoft, DeepSeek, Cohere, etc.)."
  type        = string
  default     = "OpenAI"
}

variable "model_sku" {
  description = "The Foundry model deployment SKU (e.g. GlobalStandard)."
  type        = string
  default     = "GlobalStandard"
}

variable "model_capacity" {
  description = "The Foundry model deployment capacity (TPM)."
  type        = number
  default     = 500
}

########## Networking ##########

variable "vnet_address_space" {
  description = "Address space for the new virtual network (only used when creating a new VNet)."
  type        = list(string)
  default     = ["192.168.0.0/16"]
}

variable "agent_subnet_prefix" {
  description = "Address prefix for the agent subnet (only used when creating a new subnet). Empty = derive /24 from vnet_address_space[0]."
  type        = string
  default     = ""
}

variable "pe_subnet_prefix" {
  description = "Address prefix for the private endpoint subnet (only used when creating a new subnet). Empty = derive /24 from vnet_address_space[0]."
  type        = string
  default     = ""
}

variable "mcp_subnet_prefix" {
  description = "Address prefix for the MCP subnet (only used when creating a new subnet). Empty = derive /24 from vnet_address_space[0]."
  type        = string
  default     = ""
}

########## BYO — Bring Your Own resources ##########
## Any variable left empty causes the corresponding resource to be created.
## Providing a resource ID references the existing resource as-is.

variable "existing_resource_group_name" {
  description = "Name of an existing resource group to deploy into. Empty = create a new one."
  type        = string
  default     = ""
}

variable "existing_vnet_id" {
  description = "Resource ID of an existing VNet. Empty = create a new one. When provided, existing subnet IDs must also be provided."
  type        = string
  default     = ""
}

variable "existing_agent_subnet_id" {
  description = "Resource ID of an existing agent subnet (must be exclusively delegated to Microsoft.App/environments). Empty = create a new one."
  type        = string
  default     = ""
}

variable "existing_pe_subnet_id" {
  description = "Resource ID of an existing private endpoint subnet. Empty = create a new one."
  type        = string
  default     = ""
}

variable "existing_mcp_subnet_id" {
  description = "Resource ID of an existing MCP subnet (must be delegated to Microsoft.App/environments). Empty = create a new one."
  type        = string
  default     = ""
}

variable "existing_storage_account_id" {
  description = "Resource ID of an existing Storage account. Empty = create a new one."
  type        = string
  default     = ""
}

variable "existing_cosmosdb_account_id" {
  description = "Resource ID of an existing Cosmos DB account. Empty = create a new one."
  type        = string
  default     = ""
}

variable "existing_ai_search_id" {
  description = "Resource ID of an existing AI Search service. Empty = create a new one."
  type        = string
  default     = ""
}

variable "existing_dns_zones_resource_group" {
  description = "Resource group containing existing private DNS zones. Empty = create new zones. When provided, all zones (privatelink.cognitiveservices.azure.com, privatelink.openai.azure.com, privatelink.services.ai.azure.com, privatelink.search.windows.net, privatelink.blob.core.windows.net, privatelink.documents.azure.com, privatelink.azurecr.io) are expected to exist in this RG."
  type        = string
  default     = ""
}

variable "existing_dns_zones_subscription_id" {
  description = "Subscription ID where existing private DNS zones live. Empty = current subscription. Only used when existing_dns_zones_resource_group is set."
  type        = string
  default     = ""
}

########## Azure Container Registry ##########

variable "enable_container_registry" {
  description = "Create a Premium ACR with a private endpoint. Required for azd deploy to push agent + MCP-server images."
  type        = bool
  default     = true
}

variable "developer_ip_cidr" {
  description = "Optional developer IP CIDR to allowlist for ACR push (e.g. '203.0.113.4/32'). When empty, ACR public access is disabled and pushes must originate inside the VNet."
  type        = string
  default     = ""
}

########## MCP HTTP Server (sample tool on the MCP subnet) ##########

variable "enable_mcp_http_server" {
  description = "Deploy the sample MCP HTTP server Container App on the MCP subnet."
  type        = bool
  default     = true
}

variable "mcp_http_server_image_tag" {
  description = "Container image tag for the MCP HTTP server. azd deploy manages this after the first push; the initial provision uses a placeholder image."
  type        = string
  default     = "latest"
}

########## Tags ##########

variable "tags" {
  description = "Common tags applied to all resources."
  type        = map(string)
  default     = {}
}
