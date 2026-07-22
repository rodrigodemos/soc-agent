########## soc-agent — Terraform port of sample 19 with SOC-agent additions ##########
##
## Feature parity with infra/bicep/main.bicep (Bicep):
##   * Private VNet + Agent/PE/MCP subnets (create-new or BYO)
##   * Foundry account with publicNetworkAccess=Disabled + networkInjections
##   * Foundry project + capability host (kind=Agents)
##   * BYO Storage / Cosmos DB / AI Search with private endpoints
##   * All required Private DNS Zones + VNet links (or BYO from central RG)
##   * Premium ACR with private endpoint + optional dev-IP allowlist
##   * Workspace-based Application Insights (public ingestion disabled)
##   * Sample MCP HTTP server as internal Container App on the MCP subnet
##   * Destroy-time purge of the AI Foundry account to release the agent subnet

## Random suffix for unique resource names when overrides are empty
resource "random_string" "unique" {
  length      = 4
  min_numeric = 4
  numeric     = true
  special     = false
  lower       = true
  upper       = false
}

## Resource group (create when no existing RG provided)
resource "azurerm_resource_group" "rg" {
  count    = local.create_rg ? 1 : 0
  name     = var.resource_group_name != "" ? var.resource_group_name : local.rg_name_default
  location = var.location
  tags     = local.common_tags
}

########## Networking ##########

resource "azurerm_virtual_network" "vnet" {
  count               = local.create_vnet ? 1 : 0
  name                = var.vnet_name != "" ? var.vnet_name : local.vnet_name_default
  address_space       = var.vnet_address_space
  location            = var.location
  resource_group_name = local.rg_name
  tags                = local.common_tags
}

resource "azurerm_subnet" "subnet_agent" {
  count                = var.existing_agent_subnet_id == "" ? 1 : 0
  name                 = "agent-subnet"
  resource_group_name  = local.vnet_rg_name
  virtual_network_name = local.vnet_name
  address_prefixes     = [local.subnet_agent_address_prefix]

  delegation {
    name = "Microsoft.App/environments"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "subnet_pe" {
  count                = var.existing_pe_subnet_id == "" ? 1 : 0
  name                 = "pe-subnet"
  resource_group_name  = local.vnet_rg_name
  virtual_network_name = local.vnet_name
  address_prefixes     = [local.subnet_pe_address_prefix]

  depends_on = [azurerm_subnet.subnet_agent]
}

resource "azurerm_subnet" "subnet_mcp" {
  count                = var.existing_mcp_subnet_id == "" ? 1 : 0
  name                 = "mcp-subnet"
  resource_group_name  = local.vnet_rg_name
  virtual_network_name = local.vnet_name
  address_prefixes     = [local.subnet_mcp_address_prefix]

  delegation {
    name = "Microsoft.App/environments"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }

  depends_on = [azurerm_subnet.subnet_pe]
}

########## Backend resources (Storage / Cosmos / AI Search) ##########

resource "azurerm_storage_account" "storage_account" {
  count               = local.create_storage ? 1 : 0
  name                = var.storage_account_name != "" ? var.storage_account_name : local.storage_name_default
  resource_group_name = local.rg_name
  location            = var.location
  tags                = local.common_tags

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "ZRS"

  shared_access_key_enabled = false

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

resource "azurerm_cosmosdb_account" "cosmosdb" {
  count               = local.create_cosmos ? 1 : 0
  name                = var.cosmos_db_name != "" ? var.cosmos_db_name : local.cosmos_name_default
  location            = var.location
  resource_group_name = local.rg_name
  tags                = local.common_tags

  offer_type        = "Standard"
  kind              = "GlobalDocumentDB"
  free_tier_enabled = false

  local_authentication_enabled  = false
  public_network_access_enabled = false

  automatic_failover_enabled       = false
  multiple_write_locations_enabled = false

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
    zone_redundant    = false
  }
}

resource "azapi_resource" "ai_search" {
  count                     = local.create_search ? 1 : 0
  type                      = "Microsoft.Search/searchServices@2024-06-01-preview"
  name                      = var.ai_search_name != "" ? var.ai_search_name : local.search_name_default
  parent_id                 = local.rg_id
  location                  = var.location
  schema_validation_enabled = false
  tags                      = local.common_tags

  body = {
    sku = {
      name = "standard"
    }
    identity = {
      type = "SystemAssigned"
    }
    properties = {
      replicaCount   = 1
      partitionCount = 1
      hostingMode    = "Default"
      semanticSearch = "disabled"

      disableLocalAuth = false
      authOptions = {
        aadOrApiKey = {
          aadAuthFailureMode = "http401WithBearerChallenge"
        }
      }

      publicNetworkAccess = "Disabled"
      networkRuleSet = {
        bypass = "None"
      }
    }
  }
}

########## Foundry account + model deployment ##########

## Wait for VNet/subnet propagation before creating AI Foundry.
## The Cognitive Services RP validates the VNet via ARM, which has eventual
## consistency. Without this delay, networkInjections can fail with
## "virtual network could not be found".
resource "time_sleep" "wait_for_subnet_propagation" {
  depends_on      = [azurerm_subnet.subnet_agent]
  create_duration = "60s"
}

resource "azapi_resource" "ai_foundry" {
  depends_on = [
    azurerm_subnet.subnet_agent,
    time_sleep.wait_for_subnet_propagation,
    azapi_resource_action.purge_ai_foundry
  ]

  type                      = "Microsoft.CognitiveServices/accounts@2025-04-01-preview"
  name                      = local.account_name
  parent_id                 = local.rg_id
  location                  = var.location
  schema_validation_enabled = false
  tags                      = local.common_tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "AIServices"
    sku = {
      name = "S0"
    }
    properties = {
      disableLocalAuth       = false
      allowProjectManagement = true
      customSubDomainName    = local.account_name

      publicNetworkAccess = "Disabled"
      networkAcls = {
        defaultAction       = "Deny"
        bypass              = "AzureServices"
        virtualNetworkRules = []
        ipRules             = []
      }

      networkInjections = [
        {
          scenario                   = "agent"
          subnetArmId                = local.subnet_agent_id
          useMicrosoftManagedNetwork = false
        }
      ]
    }
  }
}

resource "azapi_resource" "model_deployment" {
  depends_on = [azapi_resource.ai_foundry]

  type                      = "Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview"
  name                      = var.model_name
  parent_id                 = azapi_resource.ai_foundry.id
  schema_validation_enabled = false

  body = {
    sku = {
      capacity = var.model_capacity
      name     = var.model_sku
    }
    properties = {
      model = {
        name    = var.model_name
        format  = var.model_format
        version = var.model_version
      }
    }
  }
}

########## Private DNS Zones + VNet Links ##########

resource "azurerm_private_dns_zone" "plz_cosmos_db" {
  count               = local.create_dns_zones ? 1 : 0
  name                = "privatelink.documents.azure.com"
  resource_group_name = local.rg_name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone" "plz_ai_search" {
  count               = local.create_dns_zones ? 1 : 0
  name                = "privatelink.search.windows.net"
  resource_group_name = local.rg_name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone" "plz_storage_blob" {
  count               = local.create_dns_zones ? 1 : 0
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = local.rg_name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone" "plz_cognitive_services" {
  count               = local.create_dns_zones ? 1 : 0
  name                = "privatelink.cognitiveservices.azure.com"
  resource_group_name = local.rg_name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone" "plz_ai_services" {
  count               = local.create_dns_zones ? 1 : 0
  name                = "privatelink.services.ai.azure.com"
  resource_group_name = local.rg_name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone" "plz_openai" {
  count               = local.create_dns_zones ? 1 : 0
  name                = "privatelink.openai.azure.com"
  resource_group_name = local.rg_name
  tags                = local.common_tags
}

## VNet links — serialized via depends_on to avoid AnotherOperationInProgress
resource "azurerm_private_dns_zone_virtual_network_link" "plz_cosmos_db_link" {
  count                 = local.create_dns_zones ? 1 : 0
  name                  = "privatelink-documents-azure-com-${local.unique_suffix}-link"
  resource_group_name   = local.rg_name
  private_dns_zone_name = azurerm_private_dns_zone.plz_cosmos_db[0].name
  virtual_network_id    = local.vnet_id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "plz_ai_search_link" {
  count                 = local.create_dns_zones ? 1 : 0
  depends_on            = [azurerm_private_dns_zone_virtual_network_link.plz_cosmos_db_link]
  name                  = "privatelink-search-windows-net-${local.unique_suffix}-link"
  resource_group_name   = local.rg_name
  private_dns_zone_name = azurerm_private_dns_zone.plz_ai_search[0].name
  virtual_network_id    = local.vnet_id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "plz_storage_blob_link" {
  count                 = local.create_dns_zones ? 1 : 0
  depends_on            = [azurerm_private_dns_zone_virtual_network_link.plz_ai_search_link]
  name                  = "privatelink-blob-core-windows-net-${local.unique_suffix}-link"
  resource_group_name   = local.rg_name
  private_dns_zone_name = azurerm_private_dns_zone.plz_storage_blob[0].name
  virtual_network_id    = local.vnet_id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "plz_cognitive_services_link" {
  count                 = local.create_dns_zones ? 1 : 0
  depends_on            = [azurerm_private_dns_zone_virtual_network_link.plz_storage_blob_link]
  name                  = "privatelink-cognitiveservices-azure-com-${local.unique_suffix}-link"
  resource_group_name   = local.rg_name
  private_dns_zone_name = azurerm_private_dns_zone.plz_cognitive_services[0].name
  virtual_network_id    = local.vnet_id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "plz_ai_services_link" {
  count                 = local.create_dns_zones ? 1 : 0
  depends_on            = [azurerm_private_dns_zone_virtual_network_link.plz_cognitive_services_link]
  name                  = "privatelink-services-ai-azure-com-${local.unique_suffix}-link"
  resource_group_name   = local.rg_name
  private_dns_zone_name = azurerm_private_dns_zone.plz_ai_services[0].name
  virtual_network_id    = local.vnet_id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "plz_openai_link" {
  count                 = local.create_dns_zones ? 1 : 0
  depends_on            = [azurerm_private_dns_zone_virtual_network_link.plz_ai_services_link]
  name                  = "privatelink-openai-azure-com-${local.unique_suffix}-link"
  resource_group_name   = local.rg_name
  private_dns_zone_name = azurerm_private_dns_zone.plz_openai[0].name
  virtual_network_id    = local.vnet_id
  registration_enabled  = false
}

########## Private Endpoints ##########

resource "azurerm_private_endpoint" "pe_storage" {
  depends_on = [azurerm_private_dns_zone_virtual_network_link.plz_openai_link]

  name                = "${local.storage_name}-${local.unique_suffix}-private-endpoint"
  location            = var.location
  resource_group_name = local.rg_name
  subnet_id           = local.subnet_pe_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "${local.storage_name}-${local.unique_suffix}-private-link-service-connection"
    private_connection_resource_id = local.storage_id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "${local.storage_name}-${local.unique_suffix}-dns-group"
    private_dns_zone_ids = [local.dns_zone_storage_blob_id]
  }
}

resource "azurerm_private_endpoint" "pe_cosmos" {
  depends_on = [azurerm_private_endpoint.pe_storage]

  name                = "${local.cosmos_name}-${local.unique_suffix}-private-endpoint"
  location            = var.location
  resource_group_name = local.rg_name
  subnet_id           = local.subnet_pe_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "${local.cosmos_name}-${local.unique_suffix}-private-link-service-connection"
    private_connection_resource_id = local.cosmos_id
    subresource_names              = ["Sql"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "${local.cosmos_name}-${local.unique_suffix}-dns-group"
    private_dns_zone_ids = [local.dns_zone_cosmos_db_id]
  }
}

resource "azurerm_private_endpoint" "pe_search" {
  depends_on = [azurerm_private_endpoint.pe_cosmos]

  name                = "${local.search_name}-${local.unique_suffix}-private-endpoint"
  location            = var.location
  resource_group_name = local.rg_name
  subnet_id           = local.subnet_pe_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "${local.search_name}-${local.unique_suffix}-private-link-service-connection"
    private_connection_resource_id = local.search_id
    subresource_names              = ["searchService"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "${local.search_name}-${local.unique_suffix}-dns-group"
    private_dns_zone_ids = [local.dns_zone_search_id]
  }
}

resource "azurerm_private_endpoint" "pe_ai_foundry" {
  depends_on = [azurerm_private_endpoint.pe_search]

  name                = "${azapi_resource.ai_foundry.name}-private-endpoint"
  location            = var.location
  resource_group_name = local.rg_name
  subnet_id           = local.subnet_pe_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "${azapi_resource.ai_foundry.name}-private-link-service-connection"
    private_connection_resource_id = azapi_resource.ai_foundry.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "${azapi_resource.ai_foundry.name}-dns-group"
    private_dns_zone_ids = [
      local.dns_zone_cognitive_services_id,
      local.dns_zone_ai_services_id,
      local.dns_zone_openai_id
    ]
  }
}

########## Foundry project + connections + RBAC + capability host ##########

resource "azapi_resource" "ai_project" {
  depends_on = [
    azurerm_private_endpoint.pe_storage,
    azurerm_private_endpoint.pe_search,
    azurerm_private_endpoint.pe_cosmos,
    azurerm_private_endpoint.pe_ai_foundry
  ]

  type                      = "Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview"
  name                      = local.project_name
  location                  = var.location
  parent_id                 = azapi_resource.ai_foundry.id
  schema_validation_enabled = false
  tags                      = local.common_tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    sku = {
      name = "S0"
    }
    properties = {
      description = "SOC Copilot agent project (private network)."
      displayName = local.project_name
    }
  }

  response_export_values = [
    "identity.principalId",
    "properties.internalId"
  ]
}

## Wait 10s for the project SMI to replicate through Entra ID
resource "time_sleep" "wait_project_identities" {
  depends_on      = [azapi_resource.ai_project]
  create_duration = "10s"
}

## Project-level connections (AAD auth).
## Gated on capability_host_exists — once the capability host is created,
## these connections are locked ("Connection is in use by the workspace
## capability host and cannot be modified or deleted") and re-applying them
## fails. On first apply the count is 1 and they're created; on re-apply the
## preprovision hook sets capability_host_exists=true and count becomes 0
## so Terraform leaves the existing connections in place.
resource "azapi_resource" "conn_cosmosdb" {
  count                     = var.capability_host_exists ? 0 : 1
  depends_on                = [azapi_resource.ai_project]
  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview"
  name                      = local.cosmos_name
  parent_id                 = azapi_resource.ai_project.id
  schema_validation_enabled = false

  body = {
    name = local.cosmos_name
    properties = {
      category = "CosmosDb"
      target   = local.cosmos_endpoint
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ResourceId = local.cosmos_id
        location   = local.cosmos_location
      }
    }
  }
}

resource "azapi_resource" "conn_storage" {
  count                     = var.capability_host_exists ? 0 : 1
  depends_on                = [azapi_resource.ai_project]
  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview"
  name                      = local.storage_name
  parent_id                 = azapi_resource.ai_project.id
  schema_validation_enabled = false

  body = {
    name = local.storage_name
    properties = {
      category = "AzureStorageAccount"
      target   = local.storage_endpoint
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ResourceId = local.storage_id
        location   = local.storage_location
      }
    }
  }
}

resource "azapi_resource" "conn_aisearch" {
  count                     = var.capability_host_exists ? 0 : 1
  depends_on                = [azapi_resource.ai_project]
  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview"
  name                      = local.search_name
  parent_id                 = azapi_resource.ai_project.id
  schema_validation_enabled = false

  body = {
    name = local.search_name
    properties = {
      category = "CognitiveSearch"
      target   = "https://${local.search_name}.search.windows.net"
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ResourceId = local.search_id
        location   = local.search_location
      }
    }
  }
}

## Role assignments for the project SMI on Storage / Cosmos / Search
resource "azurerm_role_assignment" "cosmosdb_operator_ai_foundry_project" {
  depends_on           = [time_sleep.wait_project_identities]
  name                 = uuidv5("dns", "${azapi_resource.ai_project.name}${azapi_resource.ai_project.output.identity.principalId}${local.rg_name}cosmosdboperator")
  scope                = local.cosmos_id
  role_definition_name = "Cosmos DB Operator"
  principal_id         = azapi_resource.ai_project.output.identity.principalId
}

resource "azurerm_role_assignment" "storage_blob_data_contributor_ai_foundry_project" {
  depends_on           = [time_sleep.wait_project_identities]
  name                 = uuidv5("dns", "${azapi_resource.ai_project.name}${azapi_resource.ai_project.output.identity.principalId}${local.storage_name}storageblobdatacontributor")
  scope                = local.storage_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azapi_resource.ai_project.output.identity.principalId
}

resource "azurerm_role_assignment" "search_index_data_contributor_ai_foundry_project" {
  depends_on           = [time_sleep.wait_project_identities]
  name                 = uuidv5("dns", "${azapi_resource.ai_project.name}${azapi_resource.ai_project.output.identity.principalId}${local.search_name}searchindexdatacontributor")
  scope                = local.search_id
  role_definition_name = "Search Index Data Contributor"
  principal_id         = azapi_resource.ai_project.output.identity.principalId
}

resource "azurerm_role_assignment" "search_service_contributor_ai_foundry_project" {
  depends_on           = [time_sleep.wait_project_identities]
  name                 = uuidv5("dns", "${azapi_resource.ai_project.name}${azapi_resource.ai_project.output.identity.principalId}${local.search_name}searchservicecontributor")
  scope                = local.search_id
  role_definition_name = "Search Service Contributor"
  principal_id         = azapi_resource.ai_project.output.identity.principalId
}

## Wait 60s for role assignments to propagate
resource "time_sleep" "wait_rbac" {
  depends_on = [
    azurerm_role_assignment.cosmosdb_operator_ai_foundry_project,
    azurerm_role_assignment.storage_blob_data_contributor_ai_foundry_project,
    azurerm_role_assignment.search_index_data_contributor_ai_foundry_project,
    azurerm_role_assignment.search_service_contributor_ai_foundry_project
  ]
  create_duration = "60s"
}

## Project capability host (kind=Agents) — the equivalent of Bicep's
## add-project-capability-host.bicep. Once this exists, the Foundry project
## can host agents that read/write threads/blobs/vectors via the connections
## configured above.
##
## Gated on capability_host_exists (same reason as the connections above):
## the capability host cannot be re-applied idempotently once it exists.
resource "azapi_resource" "ai_foundry_project_capability_host" {
  count = var.capability_host_exists ? 0 : 1
  depends_on = [
    azapi_resource.conn_cosmosdb,
    azapi_resource.conn_storage,
    azapi_resource.conn_aisearch,
    time_sleep.wait_rbac
  ]

  type                      = "Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview"
  name                      = "caphostproj"
  parent_id                 = azapi_resource.ai_project.id
  schema_validation_enabled = false

  body = {
    properties = {
      capabilityHostKind       = "Agents"
      vectorStoreConnections   = [local.search_name]
      storageConnections       = [local.storage_name]
      threadStorageConnections = [local.cosmos_name]
    }
  }
}

## Post-caphost data-plane role assignments
resource "azurerm_cosmosdb_sql_role_assignment" "cosmosdb_db_sql_role_aifp" {
  depends_on          = [azapi_resource.ai_foundry_project_capability_host]
  name                = uuidv5("dns", "${azapi_resource.ai_project.name}${azapi_resource.ai_project.output.identity.principalId}cosmosdb_dbsqlrole")
  resource_group_name = local.cosmos_rg_name
  account_name        = local.cosmos_name
  scope               = local.cosmos_id
  role_definition_id  = "${local.cosmos_id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = azapi_resource.ai_project.output.identity.principalId
}

resource "azurerm_role_assignment" "storage_blob_data_owner_ai_foundry_project" {
  depends_on           = [azapi_resource.ai_foundry_project_capability_host]
  name                 = uuidv5("dns", "${azapi_resource.ai_project.name}${azapi_resource.ai_project.output.identity.principalId}${local.storage_name}storageblobdataowner")
  scope                = local.storage_id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azapi_resource.ai_project.output.identity.principalId
  condition_version    = "2.0"
  condition            = <<-EOT
  (
    (
      !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read'})
      AND !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/filter/action'})
      AND !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/write'})
    )
    OR
    (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringStartsWithIgnoreCase '${local.project_id_guid}'
    AND @Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringLikeIgnoreCase '*-azureml-agent')
  )
  EOT
}

########## Application Insights + Log Analytics (private ingestion via AMPLS) ##########
##
## Workspace-based Application Insights with publicNetworkAccessForIngestion=Disabled.
## The Foundry account gets an AppInsights connection so the hosted agent exports OTel
## traces to this workspace. The bicep version also creates an Azure Monitor Private
## Link Scope (AMPLS) so trace ingestion reaches AppInsights over the private VNet;
## the AMPLS bit is intentionally omitted here to keep the terraform port lean — add
## azurerm_monitor_private_link_scope + linked_service resources if you need it.

resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-${local.unique_suffix}"
  resource_group_name = local.rg_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}

resource "azurerm_application_insights" "appi" {
  name                       = "appi-${local.unique_suffix}"
  resource_group_name        = local.rg_name
  location                   = var.location
  application_type           = "web"
  workspace_id               = azurerm_log_analytics_workspace.law.id
  internet_ingestion_enabled = false
  internet_query_enabled     = true
  tags                       = local.common_tags
}

resource "azapi_resource" "conn_appinsights" {
  depends_on                = [azapi_resource.ai_foundry, azurerm_application_insights.appi]
  type                      = "Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview"
  name                      = "${local.account_name}-appinsights"
  parent_id                 = azapi_resource.ai_foundry.id
  schema_validation_enabled = false

  body = {
    properties = {
      category      = "AppInsights"
      target        = azurerm_application_insights.appi.id
      authType      = "ApiKey"
      isSharedToAll = true
      credentials = {
        key = azurerm_application_insights.appi.connection_string
      }
      metadata = {
        ApiType    = "Azure"
        ResourceId = azurerm_application_insights.appi.id
      }
    }
  }
}

########## Azure Container Registry (Premium + PE + AcrPull) ##########

resource "azurerm_container_registry" "acr" {
  count                         = var.enable_container_registry ? 1 : 0
  name                          = var.acr_name != "" ? var.acr_name : local.acr_name_default
  resource_group_name           = local.rg_name
  location                      = var.location
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = var.developer_ip_cidr != "" ? true : false
  tags                          = local.common_tags

  dynamic "network_rule_set" {
    for_each = var.developer_ip_cidr != "" ? [1] : []
    content {
      default_action = "Deny"
      ip_rule {
        action   = "Allow"
        ip_range = var.developer_ip_cidr
      }
    }
  }
}

resource "azurerm_private_dns_zone" "plz_acr" {
  count               = var.enable_container_registry && local.create_dns_zones ? 1 : 0
  name                = "privatelink.azurecr.io"
  resource_group_name = local.rg_name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "plz_acr_link" {
  count                 = var.enable_container_registry && local.create_dns_zones ? 1 : 0
  depends_on            = [azurerm_private_dns_zone_virtual_network_link.plz_openai_link]
  name                  = "privatelink-azurecr-io-${local.unique_suffix}-link"
  resource_group_name   = local.rg_name
  private_dns_zone_name = azurerm_private_dns_zone.plz_acr[0].name
  virtual_network_id    = local.vnet_id
  registration_enabled  = false
}

resource "azurerm_private_endpoint" "pe_acr" {
  count = var.enable_container_registry ? 1 : 0

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.plz_acr_link,
    azurerm_private_endpoint.pe_ai_foundry
  ]

  name                = "${azurerm_container_registry.acr[0].name}-private-endpoint"
  location            = var.location
  resource_group_name = local.rg_name
  subnet_id           = local.subnet_pe_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "${azurerm_container_registry.acr[0].name}-private-link-service-connection"
    private_connection_resource_id = azurerm_container_registry.acr[0].id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "${azurerm_container_registry.acr[0].name}-dns-group"
    private_dns_zone_ids = [local.dns_zone_acr_id]
  }
}

resource "azurerm_role_assignment" "acr_pull_project" {
  count      = var.enable_container_registry ? 1 : 0
  depends_on = [azapi_resource.ai_project, azurerm_container_registry.acr]

  name                 = uuidv5("dns", "${azapi_resource.ai_project.name}${azapi_resource.ai_project.output.identity.principalId}acr${local.unique_suffix}acrpull")
  scope                = azurerm_container_registry.acr[0].id
  role_definition_name = "AcrPull"
  principal_id         = azapi_resource.ai_project.output.identity.principalId
}

########## Sample MCP HTTP server (Container App on the MCP subnet) ##########
##
## Internal-only Container Apps environment + Container App tagged for
## `azd deploy mcp-http-server` to update the image. Bootstrap uses a public
## quickstart image so the ACA revision provisions cleanly before the first
## azd deploy pushes the real one.

resource "azurerm_container_app_environment" "mcp_env" {
  count                          = var.enable_mcp_http_server ? 1 : 0
  name                           = "cae-mcp-${local.unique_suffix}"
  location                       = var.location
  resource_group_name            = local.rg_name
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.law.id
  infrastructure_subnet_id       = local.subnet_mcp_id
  internal_load_balancer_enabled = true
  tags                           = local.common_tags
}

resource "azurerm_container_app" "mcp_app" {
  count                        = var.enable_mcp_http_server ? 1 : 0
  name                         = "ca-mcp-http-server-${local.unique_suffix}"
  container_app_environment_id = azurerm_container_app_environment.mcp_env[0].id
  resource_group_name          = local.rg_name
  revision_mode                = "Single"
  tags                         = merge(local.common_tags, { "azd-service-name" = "mcp-http-server" })

  identity {
    type = "SystemAssigned"
  }

  dynamic "registry" {
    for_each = var.enable_container_registry ? [1] : []
    content {
      server   = azurerm_container_registry.acr[0].login_server
      identity = "system"
    }
  }

  ingress {
    external_enabled = false
    target_port      = 8080
    transport        = "auto"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 3

    container {
      name   = "mcp-http-server"
      image  = var.enable_container_registry ? "${azurerm_container_registry.acr[0].login_server}/mcp-http-server:${var.mcp_http_server_image_tag}" : "mcr.microsoft.com/k8se/quickstart:latest"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "PORT"
        value = "8080"
      }
    }
  }
}

## Grant the container app's SMI AcrPull so it can pull from the private ACR.
resource "azurerm_role_assignment" "mcp_app_acr_pull" {
  count      = var.enable_mcp_http_server && var.enable_container_registry ? 1 : 0
  depends_on = [azurerm_container_app.mcp_app, azurerm_container_registry.acr]

  name                 = uuidv5("dns", "${azurerm_container_app.mcp_app[0].name}${azurerm_container_app.mcp_app[0].identity[0].principal_id}mcpapp_acrpull")
  scope                = azurerm_container_registry.acr[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_container_app.mcp_app[0].identity[0].principal_id
}

########## Destroy-time: purge the Foundry account so the agent subnet is released ##########
##
## Without this, deleting the RG leaves a soft-deleted CognitiveServices account
## holding a serviceAssociationLink on the agent subnet, and the subnet can't be
## reused for ~indefinitely.
##
## `time_sleep.purge_ai_foundry_cooldown` gives the backend 10-15 min to remove
## the /subnets/<agent>/serviceAssociationLinks/legionservicelink before the
## purge DELETE runs.

resource "azapi_resource_action" "purge_ai_foundry" {
  method      = "DELETE"
  resource_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.CognitiveServices/locations/${var.location}/resourceGroups/${local.rg_name}/deletedAccounts/${local.account_name}"
  type        = "Microsoft.CognitiveServices/locations/resourceGroups/deletedAccounts@2021-04-30"
  when        = "destroy"

  depends_on = [time_sleep.purge_ai_foundry_cooldown]
}

resource "time_sleep" "purge_ai_foundry_cooldown" {
  destroy_duration = "900s"
  depends_on       = [azurerm_subnet.subnet_agent]
}
