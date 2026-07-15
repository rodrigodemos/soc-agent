########## Data sources ##########

data "azurerm_client_config" "current" {}

## Existing Storage Account — needed for primary_blob_endpoint / location metadata
data "azurerm_storage_account" "existing" {
  count               = local.create_storage ? 0 : 1
  name                = split("/", var.existing_storage_account_id)[8]
  resource_group_name = split("/", var.existing_storage_account_id)[4]
}

## Existing Cosmos DB — needed for endpoint / location metadata
data "azurerm_cosmosdb_account" "existing" {
  count               = local.create_cosmos ? 0 : 1
  name                = split("/", var.existing_cosmosdb_account_id)[8]
  resource_group_name = split("/", var.existing_cosmosdb_account_id)[4]
}

## Existing AI Search — needed for location metadata in project connection
data "azapi_resource" "existing_search" {
  count                  = local.create_search ? 0 : 1
  type                   = "Microsoft.Search/searchServices@2024-06-01-preview"
  resource_id            = var.existing_ai_search_id
  response_export_values = ["location"]
}
