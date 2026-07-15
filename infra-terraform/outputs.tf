########## azd-consumed outputs ##########
## Names match infra/main.bicep so the azd env keys are identical whether the
## deployment came from Bicep or Terraform.

output "AZURE_LOCATION" {
  value = var.location
}

output "AZURE_TENANT_ID" {
  value = data.azurerm_client_config.current.tenant_id
}

output "AZURE_RESOURCE_GROUP" {
  value = local.rg_name
}

########## Foundry ##########

output "AZURE_AI_ACCOUNT_NAME" {
  value = azapi_resource.ai_foundry.name
}

output "AZURE_AI_PROJECT_NAME" {
  value = azapi_resource.ai_project.name
}

output "AZURE_AI_PROJECT_ENDPOINT" {
  value = "https://${azapi_resource.ai_foundry.name}.services.ai.azure.com/api/projects/${azapi_resource.ai_project.name}"
}

output "FOUNDRY_PROJECT_ENDPOINT" {
  value = "https://${azapi_resource.ai_foundry.name}.services.ai.azure.com/api/projects/${azapi_resource.ai_project.name}"
}

output "AZURE_AI_MODEL_DEPLOYMENT_NAME" {
  value = var.model_name
}

########## Backend services ##########

output "AZURE_STORAGE_ACCOUNT_NAME" {
  value = local.storage_name
}

output "AZURE_STORAGE_ACCOUNT_ID" {
  value = local.storage_id
}

output "AZURE_COSMOS_DB_ACCOUNT_NAME" {
  value = local.cosmos_name
}

output "AZURE_COSMOS_DB_ACCOUNT_ID" {
  value = local.cosmos_id
}

output "AZURE_AI_SEARCH_NAME" {
  value = local.search_name
}

output "AZURE_AI_SEARCH_ID" {
  value = local.search_id
}

########## Networking ##########

output "AZURE_VNET_ID" {
  value = local.vnet_id
}

output "AZURE_VNET_NAME" {
  value = local.vnet_name
}

output "AZURE_AGENT_SUBNET_ID" {
  value = local.subnet_agent_id
}

output "AZURE_PE_SUBNET_ID" {
  value = local.subnet_pe_id
}

output "AZURE_MCP_SUBNET_ID" {
  value = local.subnet_mcp_id
}

########## ACR ##########

output "AZURE_CONTAINER_REGISTRY_ENDPOINT" {
  value = var.enable_container_registry ? azurerm_container_registry.acr[0].login_server : ""
}

output "AZURE_CONTAINER_REGISTRY_NAME" {
  value = var.enable_container_registry ? azurerm_container_registry.acr[0].name : ""
}

########## Monitoring ##########

output "APPLICATIONINSIGHTS_RESOURCE_ID" {
  value = azurerm_application_insights.appi.id
}

output "APPLICATIONINSIGHTS_CONNECTION_STRING" {
  value     = azurerm_application_insights.appi.connection_string
  sensitive = true
}

########## MCP HTTP server ##########

output "MCP_HTTP_SERVER_FQDN" {
  value = var.enable_mcp_http_server ? azurerm_container_app.mcp_app[0].ingress[0].fqdn : ""
}

output "AZURE_CONTAINER_APPS_ENVIRONMENT_ID" {
  value = var.enable_mcp_http_server ? azurerm_container_app_environment.mcp_env[0].id : ""
}

output "AZURE_CONTAINER_APPS_ENVIRONMENT_NAME" {
  value = var.enable_mcp_http_server ? azurerm_container_app_environment.mcp_env[0].name : ""
}
