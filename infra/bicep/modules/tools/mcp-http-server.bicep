/*
  MCP HTTP Server on the MCP subnet
  ---------------------------------
  Creates an internal-only Container Apps environment bound to the MCP subnet
  and a Container App for the sample MCP HTTP server, tagged for `azd deploy`.

  The Container App pulls its image from the private ACR via system-assigned
  managed identity (the AcrPull role assignment happens in the ACR module
  using the project SMI for the agent path; here we also assign AcrPull to
  the Container App's own SMI).

  Initial image is `mcr.microsoft.com/k8se/quickstart:latest` as a bootstrap
  placeholder so the Container App provisions cleanly before `azd deploy`
  pushes the real image and updates the revision.
*/

@description('Azure region for the Container Apps env and app.')
param location string

@description('Suffix for unique resource names.')
param suffix string

@description('Tags applied to created resources (must include `azd-env-name`).')
param tags object

@description('Resource ID of the MCP subnet (delegated to Microsoft.App/environments).')
param mcpSubnetId string

@description('ACR login server (e.g. `myacr.azurecr.io`). Empty string disables registry pull (uses placeholder image).')
param acrLoginServer string

@description('ACR resource name (for the AcrPull role assignment scope). Empty when ACR is disabled.')
param acrName string

@description('Log Analytics workspace resource ID for Container Apps env logging.')
param logAnalyticsWorkspaceId string

@description('Container image tag for the MCP HTTP server (azd manages this; bootstrap to `latest`).')
param imageTag string = 'latest'

@description('Container app name. Tagged so `azd deploy mcp-http-server` targets it.')
param containerAppName string = 'ca-mcp-http-server-${suffix}'

@description('Container Apps environment name.')
param environmentName string = 'cae-mcp-${suffix}'

var serviceName = 'mcp-http-server'
var placeholderImage = 'mcr.microsoft.com/k8se/quickstart:latest'
var imageRef = empty(acrLoginServer) ? placeholderImage : '${acrLoginServer}/${serviceName}:${imageTag}'

// Look up the Log Analytics workspace to read its shared key.
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: last(split(logAnalyticsWorkspaceId, '/'))
}

// Container Apps environment on the MCP subnet (internal only).
resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      internal: true
      infrastructureSubnetId: mcpSubnetId
    }
    zoneRedundant: false
  }
}

// The Container App. SMI for ACR pull; ingress on port 8080 over MCP streamable HTTP.
resource mcpApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: location
  tags: union(tags, { 'azd-service-name': serviceName })
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: 8080
        transport: 'auto'
        traffic: [
          {
            weight: 100
            latestRevision: true
          }
        ]
      }
      registries: empty(acrLoginServer) ? [] : [
        {
          server: acrLoginServer
          identity: 'system'
        }
      ]
    }
    template: {
      containers: [
        {
          name: serviceName
          image: imageRef
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'PORT'
              value: '8080'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

// Grant the Container App's SMI AcrPull so it can pull from the private ACR.
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource acrResource 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = if (!empty(acrName)) {
  name: acrName
}

resource appAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(acrName)) {
  name: guid(mcpApp.id, acrPullRoleId, 'mcp-app-acr-pull')
  scope: acrResource
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: mcpApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

@description('Internal FQDN of the MCP HTTP server (only reachable from the VNet).')
output fqdn string = mcpApp.properties.configuration.ingress.fqdn

@description('Container Apps environment resource ID.')
output environmentId string = environment.id

@description('Container Apps environment name.')
output environmentName string = environment.name

@description('Container App resource name.')
output containerAppName string = mcpApp.name
