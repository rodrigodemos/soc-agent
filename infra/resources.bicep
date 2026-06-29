/*
  soc-agent — Resource-group-scoped workload module.

  Port of the upstream sample 19 `main.bicep`
  (microsoft-foundry/foundry-samples → 19-private-network-agent-tools)
  with:
    * module paths updated to `modules/<subfolder>/...`
    * an extra MCP HTTP server Container App on the MCP subnet
    * Application Insights connection string surfaced for both the agent and
      the MCP server

  All upstream semantics are preserved: BYO VNet/subnets, BYO Cosmos/Search/
  Storage, private endpoints + DNS, Azure Monitor Private Link Scope for
  trace ingestion, capability host wired via Bicep (no bash script needed).
*/

@description('Azure region for all resources.')
param location string

@description('Common tags applied to all created resources.')
param tags object = {}

@description('Object ID of the user or SPN running azd. Reserved for future dev RBAC modules (e.g., granting the developer direct AcrPush over Bastion). Pass-through from `main.bicep`.')
param principalId string = ''

@description('Principal type of `principalId`. Reserved for future dev RBAC modules.')
@allowed([
  'User'
  'ServicePrincipal'
])
param principalType string = 'User'

// Reference the reserved params once so linter does not flag them as unused
// while preserving them as a documented extension point.
var _reservedPrincipal = '${principalId}-${principalType}'

// Foundry / model
param aiServices string
param firstProjectName string
param modelName string
param modelFormat string
param modelVersion string
param modelSkuName string
param modelCapacity int

// VNet
param vnetName string
param agentSubnetName string
param peSubnetName string
param mcpSubnetName string
param vnetAddressPrefix string
param agentSubnetPrefix string
param peSubnetPrefix string
param mcpSubnetPrefix string
param existingVnetResourceId string
param existingAgentSubnetResourceId string
param existingPeSubnetResourceId string
param existingMcpSubnetResourceId string

// BYO backends
param existingAiSearchResourceId string
param existingAzureStorageAccountResourceId string
param existingAzureCosmosDBAccountResourceId string

// DNS
param existingDnsZones object
param existingMonitorDnsZones object

// ACR
param enableContainerRegistry bool
param developerIpCidr string

// MCP HTTP server
param enableMcpHttpServer bool
param mcpHttpServerImageTag string

@description('Optional. Project description for the Foundry project.')
param projectDescription string = 'SOC Copilot agent project (private network).'

@description('Optional. Display name for the Foundry project.')
param projectDisplayName string = 'soc-copilot project'

@description('Name of the project capability host.')
param projectCapHost string = 'caphostproj'

// ── Derived names ───────────────────────────────────────────────────────────

var uniqueSuffix = substring(uniqueString(resourceGroup().id), 0, 4)
var accountName = toLower('${aiServices}${uniqueSuffix}')
var projectName = toLower('${firstProjectName}${uniqueSuffix}')
var cosmosDBName = toLower('${aiServices}${uniqueSuffix}cosmos')
var aiSearchName = toLower('${aiServices}${uniqueSuffix}search')
var azureStorageName = toLower('${aiServices}${uniqueSuffix}stor')
var acrName = toLower('acr${uniqueSuffix}${uniqueString(resourceGroup().id)}')

// Existence flags
var storagePassedIn = existingAzureStorageAccountResourceId != ''
var searchPassedIn = existingAiSearchResourceId != ''
var cosmosPassedIn = existingAzureCosmosDBAccountResourceId != ''
var existingVnetPassedIn = existingVnetResourceId != ''
var agentSubnetExists = existingAgentSubnetResourceId != ''
var peSubnetExists = existingPeSubnetResourceId != ''
var mcpSubnetExists = existingMcpSubnetResourceId != ''

// Effective subnet names derive from ARM IDs when provided
var effectiveAgentSubnetName = agentSubnetExists ? last(split(existingAgentSubnetResourceId, '/')) : agentSubnetName
var effectivePeSubnetName = peSubnetExists ? last(split(existingPeSubnetResourceId, '/')) : peSubnetName
var effectiveMcpSubnetName = mcpSubnetExists ? last(split(existingMcpSubnetResourceId, '/')) : mcpSubnetName

// BYO resource locations
var acsParts = split(existingAiSearchResourceId, '/')
var aiSearchServiceSubscriptionId = searchPassedIn ? acsParts[2] : subscription().subscriptionId
var aiSearchServiceResourceGroupName = searchPassedIn ? acsParts[4] : resourceGroup().name

var cosmosParts = split(existingAzureCosmosDBAccountResourceId, '/')
var cosmosDBSubscriptionId = cosmosPassedIn ? cosmosParts[2] : subscription().subscriptionId
var cosmosDBResourceGroupName = cosmosPassedIn ? cosmosParts[4] : resourceGroup().name

var storageParts = split(existingAzureStorageAccountResourceId, '/')
var azureStorageSubscriptionId = storagePassedIn ? storageParts[2] : subscription().subscriptionId
var azureStorageResourceGroupName = storagePassedIn ? storageParts[4] : resourceGroup().name

var vnetParts = split(existingVnetResourceId, '/')
var vnetSubscriptionId = existingVnetPassedIn ? vnetParts[2] : subscription().subscriptionId
var vnetResourceGroupName = existingVnetPassedIn ? vnetParts[4] : resourceGroup().name
var existingVnetName = existingVnetPassedIn ? last(vnetParts) : vnetName
var trimVnetName = trim(existingVnetName)

// ── VNet ────────────────────────────────────────────────────────────────────

module vnet 'modules/network/network-agent-vnet.bicep' = {
  name: 'vnet-${trimVnetName}-${uniqueSuffix}-deployment'
  params: {
    location: location
    vnetName: trimVnetName
    useExistingVnet: existingVnetPassedIn
    existingVnetResourceGroupName: vnetResourceGroupName
    agentSubnetName: effectiveAgentSubnetName
    peSubnetName: effectivePeSubnetName
    mcpSubnetName: effectiveMcpSubnetName
    vnetAddressPrefix: vnetAddressPrefix
    agentSubnetPrefix: agentSubnetPrefix
    peSubnetPrefix: peSubnetPrefix
    mcpSubnetPrefix: mcpSubnetPrefix
    existingVnetSubscriptionId: vnetSubscriptionId
    agentSubnetExists: agentSubnetExists
    peSubnetExists: peSubnetExists
    mcpSubnetExists: mcpSubnetExists
  }
}

// ── Foundry account + model deployment ──────────────────────────────────────
//
// The aiAccount module sets networkInjections referencing agentSubnetId, which
// gives Bicep an implicit dependency on the vnet module. Note: the AML AI
// Agent Service control plane validates the subnet at account-create time via
// an out-of-band lookup that has occasional eventual-consistency lag against
// the freshly created VNet. If that lag triggers a "vnet not found" failure
// during account create, see docs/TROUBLESHOOTING.md for remediation
// (retry after purge, or fall back to scripts/createCapHost.sh).
module aiAccount 'modules/ai/ai-account-identity.bicep' = {
  name: '${accountName}-${uniqueSuffix}-deployment'
  params: {
    accountName: accountName
    location: location
    modelName: modelName
    modelFormat: modelFormat
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    modelCapacity: modelCapacity
    agentSubnetId: vnet.outputs.agentSubnetId
  }
}

// ── Backend dependencies (BYO or create) ────────────────────────────────────

module aiDependencies 'modules/dependencies/standard-dependent-resources.bicep' = {
  name: 'dependencies-${uniqueSuffix}-deployment'
  params: {
    location: location
    azureStorageName: azureStorageName
    aiSearchName: aiSearchName
    cosmosDBName: cosmosDBName
    existingAiSearchResourceId: existingAiSearchResourceId
    aiSearchExists: searchPassedIn
    existingAzureStorageAccountResourceId: existingAzureStorageAccountResourceId
    azureStorageExists: storagePassedIn
    existingCosmosDBResourceId: existingAzureCosmosDBAccountResourceId
    cosmosDBExists: cosmosPassedIn
  }
}

// ── Private endpoints + DNS ─────────────────────────────────────────────────

module privateEndpointAndDNS 'modules/privatelink/private-endpoint-and-dns.bicep' = {
  name: '${uniqueSuffix}-private-endpoint'
  params: {
    aiAccountName: aiAccount.outputs.accountName
    aiSearchName: aiDependencies.outputs.aiSearchName
    storageName: aiDependencies.outputs.azureStorageName
    cosmosDBName: aiDependencies.outputs.cosmosDBName
    fabricWorkspaceResourceId: ''
    vnetName: vnet.outputs.virtualNetworkName
    peSubnetName: vnet.outputs.peSubnetName
    suffix: uniqueSuffix
    vnetResourceGroupName: vnet.outputs.virtualNetworkResourceGroup
    vnetSubscriptionId: vnet.outputs.virtualNetworkSubscriptionId
    cosmosDBSubscriptionId: cosmosDBSubscriptionId
    cosmosDBResourceGroupName: cosmosDBResourceGroupName
    aiSearchSubscriptionId: aiSearchServiceSubscriptionId
    aiSearchResourceGroupName: aiSearchServiceResourceGroupName
    storageAccountResourceGroupName: azureStorageResourceGroupName
    storageAccountSubscriptionId: azureStorageSubscriptionId
    existingDnsZones: existingDnsZones
  }
}

// ── Application Insights (private ingestion via AMPLS) ──────────────────────

module applicationInsights 'modules/monitoring/application-insights.bicep' = {
  name: 'app-insights-${uniqueSuffix}-deployment'
  params: {
    location: location
    suffix: uniqueSuffix
    aiAccountName: aiAccount.outputs.accountName
    disablePublicIngestion: true
  }
}

module monitorPrivateLink 'modules/privatelink/monitor-private-link-scope.bicep' = {
  name: 'monitor-pls-${uniqueSuffix}-deployment'
  params: {
    location: location
    suffix: uniqueSuffix
    appInsightsId: applicationInsights.outputs.appInsightsId
    logAnalyticsId: applicationInsights.outputs.logAnalyticsId
    vnetId: vnet.outputs.virtualNetworkId
    peSubnetId: vnet.outputs.peSubnetId
    existingDnsZones: existingMonitorDnsZones
  }
  dependsOn: [
    privateEndpointAndDNS
  ]
}

// ── Project + role assignments + capability host ────────────────────────────

module aiProject 'modules/ai/ai-project-identity.bicep' = {
  name: '${projectName}-${uniqueSuffix}-deployment'
  params: {
    projectName: projectName
    projectDescription: projectDescription
    displayName: projectDisplayName
    location: location
    aiSearchName: aiDependencies.outputs.aiSearchName
    aiSearchServiceResourceGroupName: aiDependencies.outputs.aiSearchServiceResourceGroupName
    aiSearchServiceSubscriptionId: aiDependencies.outputs.aiSearchServiceSubscriptionId
    cosmosDBName: aiDependencies.outputs.cosmosDBName
    cosmosDBSubscriptionId: aiDependencies.outputs.cosmosDBSubscriptionId
    cosmosDBResourceGroupName: aiDependencies.outputs.cosmosDBResourceGroupName
    azureStorageName: aiDependencies.outputs.azureStorageName
    azureStorageSubscriptionId: aiDependencies.outputs.azureStorageSubscriptionId
    azureStorageResourceGroupName: aiDependencies.outputs.azureStorageResourceGroupName
    accountName: aiAccount.outputs.accountName
  }
  dependsOn: [
    privateEndpointAndDNS
  ]
}

module formatProjectWorkspaceId 'modules/ai/format-project-workspace-id.bicep' = {
  name: 'format-project-workspace-id-${uniqueSuffix}-deployment'
  params: {
    projectWorkspaceId: aiProject.outputs.projectWorkspaceId
  }
}

module storageAccountRoleAssignment 'modules/roles/azure-storage-account-role-assignment.bicep' = {
  name: 'storage-ra-${uniqueSuffix}-deployment'
  scope: resourceGroup(azureStorageSubscriptionId, azureStorageResourceGroupName)
  params: {
    azureStorageName: aiDependencies.outputs.azureStorageName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    privateEndpointAndDNS
  ]
}

module cosmosAccountRoleAssignments 'modules/roles/cosmosdb-account-role-assignment.bicep' = {
  name: 'cosmos-account-ra-${uniqueSuffix}-deployment'
  scope: resourceGroup(cosmosDBSubscriptionId, cosmosDBResourceGroupName)
  params: {
    cosmosDBName: aiDependencies.outputs.cosmosDBName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    privateEndpointAndDNS
  ]
}

module aiSearchRoleAssignments 'modules/roles/ai-search-role-assignments.bicep' = {
  name: 'ai-search-ra-${uniqueSuffix}-deployment'
  scope: resourceGroup(aiSearchServiceSubscriptionId, aiSearchServiceResourceGroupName)
  params: {
    aiSearchName: aiDependencies.outputs.aiSearchName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    privateEndpointAndDNS
  ]
}

module addProjectCapabilityHost 'modules/ai/add-project-capability-host.bicep' = {
  name: 'capabilityHost-configuration-${uniqueSuffix}-deployment'
  params: {
    accountName: aiAccount.outputs.accountName
    projectName: aiProject.outputs.projectName
    cosmosDBConnection: aiProject.outputs.cosmosDBConnection
    azureStorageConnection: aiProject.outputs.azureStorageConnection
    aiSearchConnection: aiProject.outputs.aiSearchConnection
    projectCapHost: projectCapHost
  }
  dependsOn: [
    privateEndpointAndDNS
    cosmosAccountRoleAssignments
    storageAccountRoleAssignment
    aiSearchRoleAssignments
  ]
}

module storageContainersRoleAssignment 'modules/roles/blob-storage-container-role-assignments.bicep' = {
  name: 'storage-containers-ra-${uniqueSuffix}-deployment'
  scope: resourceGroup(azureStorageSubscriptionId, azureStorageResourceGroupName)
  params: {
    aiProjectPrincipalId: aiProject.outputs.projectPrincipalId
    storageName: aiDependencies.outputs.azureStorageName
    workspaceId: formatProjectWorkspaceId.outputs.projectWorkspaceIdGuid
  }
  dependsOn: [
    addProjectCapabilityHost
    storageAccountRoleAssignment
  ]
}

module cosmosContainerRoleAssignments 'modules/roles/cosmos-container-role-assignments.bicep' = {
  name: 'cosmos-containers-ra-${uniqueSuffix}-deployment'
  scope: resourceGroup(cosmosDBSubscriptionId, cosmosDBResourceGroupName)
  params: {
    cosmosAccountName: aiDependencies.outputs.cosmosDBName
    projectWorkspaceId: formatProjectWorkspaceId.outputs.projectWorkspaceIdGuid
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    addProjectCapabilityHost
    storageContainersRoleAssignment
  ]
}

// ── ACR (Premium + PE + optional dev-IP allowlist) ──────────────────────────

module acr 'modules/registry/container-registry.bicep' = if (enableContainerRegistry) {
  name: 'acr-${uniqueSuffix}-deployment'
  params: {
    acrName: substring(acrName, 0, min(length(acrName), 50))
    location: location
    peSubnetId: vnet.outputs.peSubnetId
    vnetId: vnet.outputs.virtualNetworkId
    suffix: uniqueSuffix
    existingDnsZoneResourceGroup: empty(existingDnsZones['privatelink.azurecr.io'].resourceGroup) ? resourceGroup().name : existingDnsZones['privatelink.azurecr.io'].resourceGroup
    dnsZonesSubscriptionId: empty(existingDnsZones['privatelink.azurecr.io'].subscriptionId) ? subscription().subscriptionId : existingDnsZones['privatelink.azurecr.io'].subscriptionId
    developerIpCidr: developerIpCidr
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    privateEndpointAndDNS
  ]
}

// ── Sample MCP HTTP server on the MCP subnet ────────────────────────────────

module mcpHttpServer 'modules/tools/mcp-http-server.bicep' = if (enableMcpHttpServer) {
  name: 'mcp-http-server-${uniqueSuffix}-deployment'
  params: {
    location: location
    suffix: uniqueSuffix
    tags: tags
    mcpSubnetId: vnet.outputs.mcpSubnetId
    acrLoginServer: enableContainerRegistry ? acr!.outputs.acrLoginServer : ''
    acrName: enableContainerRegistry ? acr!.outputs.acrName : ''
    logAnalyticsWorkspaceId: applicationInsights.outputs.logAnalyticsId
    imageTag: mcpHttpServerImageTag
  }
  dependsOn: [
    addProjectCapabilityHost
  ]
}

// ── Outputs (consumed by main.bicep) ────────────────────────────────────────

output aiAccountName string = aiAccount.outputs.accountName
output aiProjectName string = aiProject.outputs.projectName
output aiProjectEndpoint string = 'https://${aiAccount.outputs.accountName}.services.ai.azure.com/api/projects/${aiProject.outputs.projectName}'
output modelDeploymentName string = modelName

output acrLoginServer string = enableContainerRegistry ? acr!.outputs.acrLoginServer : ''
output acrName string = enableContainerRegistry ? acr!.outputs.acrName : ''

output appInsightsId string = applicationInsights.outputs.appInsightsId

output mcpHttpServerFqdn string = enableMcpHttpServer ? mcpHttpServer!.outputs.fqdn : ''
output containerAppsEnvironmentId string = enableMcpHttpServer ? mcpHttpServer!.outputs.environmentId : ''
output containerAppsEnvironmentName string = enableMcpHttpServer ? mcpHttpServer!.outputs.environmentName : ''

// Internal: prevents linter no-unused-params warnings for reserved pass-through params.
output _reservedPrincipal string = _reservedPrincipal
