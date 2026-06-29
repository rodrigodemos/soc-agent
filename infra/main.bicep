/*
  soc-agent — Top-level subscription-scoped Bicep template.

  Creates (or reuses) the deployment resource group, then delegates to
  `resources.bicep` (resource-group scope) which provisions:

    * Private VNet with Agent / PE / MCP subnets (or BYO existing VNet+subnets)
    * Foundry account + project on the private VNet, public access disabled
    * Project capability host (agents kind) — no external script needed
    * BYO Cosmos DB / Azure AI Search / Storage with private endpoints
    * Premium ACR with private endpoint and optional dev-IP allowlist for push
    * Workspace-based Application Insights with private ingestion (AMPLS)
    * A sample MCP HTTP server Container App on the MCP subnet

  Run with `azd up`. Parameters are bound via `main.parameters.json`.
*/

targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment; used in the resource-group name and as a salt for resource naming.')
param environmentName string

@minLength(1)
@maxLength(90)
@description('Resource group to create or reuse.')
param resourceGroupName string = 'rg-${environmentName}'

@allowed([
  'westus'
  'westus2'
  'westus3'
  'eastus'
  'eastus2'
  'southcentralus'
  'northcentralus'
  'canadacentral'
  'canadaeast'
  'brazilsouth'
  'francecentral'
  'germanywestcentral'
  'italynorth'
  'spaincentral'
  'swedencentral'
  'switzerlandnorth'
  'norwayeast'
  'polandcentral'
  'uksouth'
  'westeurope'
  'uaenorth'
  'southafricanorth'
  'japaneast'
  'koreacentral'
  'southeastasia'
  'southindia'
  'australiaeast'
])
@description('Primary Azure region for all resources.')
param location string

@description('Object ID of the user or service principal running azd; used for any direct role assignments needed for dev access.')
param principalId string = ''

@description('Principal type of `principalId` ("User" or "ServicePrincipal").')
@allowed([
  'User'
  'ServicePrincipal'
])
param principalType string = 'User'

// ── Foundry / model ─────────────────────────────────────────────────────────

@minLength(2)
@maxLength(40)
@description('Name prefix for the Foundry (AI Services) account. A 4-char suffix is appended.')
param aiServices string = 'aifoundry'

@minLength(2)
@maxLength(40)
@description('Name prefix for the Foundry project. A 4-char suffix is appended.')
param firstProjectName string = 'project'

@description('Model to deploy to the Foundry account.')
param modelName string = 'gpt-4o-mini'

@description('Model provider.')
param modelFormat string = 'OpenAI'

@description('Model version.')
param modelVersion string = '2024-07-18'

@description('Model deployment SKU.')
param modelSkuName string = 'GlobalStandard'

@description('Tokens-per-minute (TPM) capacity for the model deployment.')
param modelCapacity int = 30

// ── Networking — new VNet defaults / BYO overrides ──────────────────────────

@description('Virtual Network name (used when creating a new VNet).')
param vnetName string = 'agent-vnet'

@description('Agent subnet name.')
param agentSubnetName string = 'agent-subnet'

@description('Private endpoint subnet name.')
param peSubnetName string = 'pe-subnet'

@description('MCP subnet name (hosts user-deployed Container Apps such as MCP servers).')
param mcpSubnetName string = 'mcp-subnet'

@description('VNet address prefix (only for new VNet). Leave empty to use module defaults.')
param vnetAddressPrefix string = ''

@description('Agent subnet address prefix. Leave empty to use module defaults.')
param agentSubnetPrefix string = ''

@description('Private endpoint subnet address prefix. Leave empty to use module defaults.')
param peSubnetPrefix string = ''

@description('MCP subnet address prefix. Leave empty to use module defaults.')
param mcpSubnetPrefix string = ''

@description('ARM Resource ID of an existing VNet. When set, the VNet is referenced and the template will create/update the three subnets inside it (unless the per-subnet ARM IDs below are also set).')
param existingVnetResourceId string = ''

@description('ARM Resource ID of an existing Agent subnet. When set, the subnet is referenced as-is.')
param existingAgentSubnetResourceId string = ''

@description('ARM Resource ID of an existing PE subnet. When set, the subnet is referenced as-is.')
param existingPeSubnetResourceId string = ''

@description('ARM Resource ID of an existing MCP subnet. When set, the subnet is referenced as-is.')
param existingMcpSubnetResourceId string = ''

// ── BYO backend resources (optional) ────────────────────────────────────────

@description('ARM Resource ID of an existing AI Search. Leave empty to create one.')
param existingAiSearchResourceId string = ''

@description('ARM Resource ID of an existing Storage account. Leave empty to create one.')
param existingAzureStorageAccountResourceId string = ''

@description('ARM Resource ID of an existing Cosmos DB account. Leave empty to create one.')
param existingAzureCosmosDBAccountResourceId string = ''

// ── DNS zones (BYO landing-zone support) ────────────────────────────────────

@description('Map of `<privatelink-zone-fqdn>: { subscriptionId, resourceGroup }`. Empty resourceGroup => create the zone in this deployment\'s RG; non-empty => reference the existing zone there.')
param existingDnsZones object = {
  'privatelink.services.ai.azure.com': { subscriptionId: '', resourceGroup: '' }
  'privatelink.openai.azure.com': { subscriptionId: '', resourceGroup: '' }
  'privatelink.cognitiveservices.azure.com': { subscriptionId: '', resourceGroup: '' }
  'privatelink.search.windows.net': { subscriptionId: '', resourceGroup: '' }
  'privatelink.blob.${environment().suffixes.storage}': { subscriptionId: '', resourceGroup: '' }
  'privatelink.documents.azure.com': { subscriptionId: '', resourceGroup: '' }
  'privatelink.azurecr.io': { subscriptionId: '', resourceGroup: '' }
}

@description('Map of Azure Monitor privatelink zone FQDN to existing zone info. Same shape as `existingDnsZones`.')
param existingMonitorDnsZones object = {
  'privatelink.monitor.azure.com': { subscriptionId: '', resourceGroup: '' }
  'privatelink.oms.opinsights.azure.com': { subscriptionId: '', resourceGroup: '' }
  'privatelink.ods.opinsights.azure.com': { subscriptionId: '', resourceGroup: '' }
  'privatelink.agentsvc.azure-automation.net': { subscriptionId: '', resourceGroup: '' }
}

// ── ACR ─────────────────────────────────────────────────────────────────────

@description('Create a Premium ACR with private endpoint. Required for `azd deploy` to push agent and MCP-server images.')
param enableContainerRegistry bool = true

@description('Optional developer IP CIDR allowlist for ACR push (e.g. "203.0.113.4/32"). When empty, ACR public access is disabled and pushes must go over the VNet (e.g. via Bastion).')
param developerIpCidr string = ''

// ── MCP tool ────────────────────────────────────────────────────────────────

@description('Deploy the sample MCP HTTP server Container App on the MCP subnet.')
param enableMcpHttpServer bool = true

@description('Container image tag for the MCP HTTP server. azd manages this via `azd deploy mcp-http-server`; leave at default for first-time bootstrap.')
param mcpHttpServerImageTag string = 'latest'

// ── Tags ────────────────────────────────────────────────────────────────────

var tags = {
  'azd-env-name': environmentName
}

// ── Resource group ──────────────────────────────────────────────────────────

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// ── Main deployment ─────────────────────────────────────────────────────────

module workload 'resources.bicep' = {
  scope: rg
  name: 'soc-agent-workload'
  params: {
    location: location
    tags: tags
    principalId: principalId
    principalType: principalType

    aiServices: aiServices
    firstProjectName: firstProjectName
    modelName: modelName
    modelFormat: modelFormat
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    modelCapacity: modelCapacity

    vnetName: vnetName
    agentSubnetName: agentSubnetName
    peSubnetName: peSubnetName
    mcpSubnetName: mcpSubnetName
    vnetAddressPrefix: vnetAddressPrefix
    agentSubnetPrefix: agentSubnetPrefix
    peSubnetPrefix: peSubnetPrefix
    mcpSubnetPrefix: mcpSubnetPrefix
    existingVnetResourceId: existingVnetResourceId
    existingAgentSubnetResourceId: existingAgentSubnetResourceId
    existingPeSubnetResourceId: existingPeSubnetResourceId
    existingMcpSubnetResourceId: existingMcpSubnetResourceId

    existingAiSearchResourceId: existingAiSearchResourceId
    existingAzureStorageAccountResourceId: existingAzureStorageAccountResourceId
    existingAzureCosmosDBAccountResourceId: existingAzureCosmosDBAccountResourceId

    existingDnsZones: existingDnsZones
    existingMonitorDnsZones: existingMonitorDnsZones

    enableContainerRegistry: enableContainerRegistry
    developerIpCidr: developerIpCidr

    enableMcpHttpServer: enableMcpHttpServer
    mcpHttpServerImageTag: mcpHttpServerImageTag
  }
}

// ── Outputs (consumed by azd) ───────────────────────────────────────────────

output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = subscription().tenantId
output AZURE_RESOURCE_GROUP string = rg.name

// Foundry
output AZURE_AI_ACCOUNT_NAME string = workload.outputs.aiAccountName
output AZURE_AI_PROJECT_NAME string = workload.outputs.aiProjectName
output AZURE_AI_PROJECT_ENDPOINT string = workload.outputs.aiProjectEndpoint
output FOUNDRY_PROJECT_ENDPOINT string = workload.outputs.aiProjectEndpoint
output AZURE_AI_MODEL_DEPLOYMENT_NAME string = workload.outputs.modelDeploymentName

// ACR
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = workload.outputs.acrLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = workload.outputs.acrName

// Application Insights (private ingestion via AMPLS)
output APPLICATIONINSIGHTS_RESOURCE_ID string = workload.outputs.appInsightsId

// MCP HTTP server
output MCP_HTTP_SERVER_FQDN string = workload.outputs.mcpHttpServerFqdn

// Container Apps environment (used by azd to deploy services with host: containerapp)
output AZURE_CONTAINER_APPS_ENVIRONMENT_ID string = workload.outputs.containerAppsEnvironmentId
output AZURE_CONTAINER_APPS_ENVIRONMENT_NAME string = workload.outputs.containerAppsEnvironmentName
