// ============================================================================
// functionApp.bicep - Azure Function App for event-driven provisioning
// ============================================================================
// Deploys:
//   - Storage Account (for Function App runtime + Durable Functions state)
//   - Log Analytics Workspace
//   - Application Insights
//   - App Service Plan (Elastic Premium EP1 for Durable Functions)
//   - Function App (PowerShell 7.4, Durable Functions)
//   - System-Assigned Managed Identity
//   - RBAC: Owner on subscription (for deployments + RBAC management)
//   - RBAC: Directory.Read.All via Graph API (configured post-deployment)
// ============================================================================

// === Parameters ===
@description('Azure region')
param location string

@description('Name prefix')
param namePrefix string

@description('Unique suffix for naming')
param uniqueSuffix string

@description('Entra ID group Object ID for sync')
param entraGroupObjectId string

@description('Billing scope for subscription creation')
param billingScope string

@description('Default warning budget (USD)')
param defaultWarningBudget int

@description('Default hard limit budget (USD)')
param defaultHardLimitBudget int

@description('Default grace period (days)')
param defaultGracePeriodDays int

@description('Timer schedule for Entra ID group sync')
param syncSchedule string

// === Variables ===
var storageAccountName = 'st${namePrefix}${uniqueSuffix}'
var appInsightsName = 'appi-${namePrefix}-${uniqueSuffix}'
var logAnalyticsName = 'log-${namePrefix}-${uniqueSuffix}'
var appServicePlanName = 'asp-${namePrefix}-${uniqueSuffix}'
var functionAppName = 'func-${namePrefix}-${uniqueSuffix}'

// === Storage Account ===
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    defaultToOAuthAuthentication: true
  }
}

// === Log Analytics ===
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// === Application Insights ===
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// === App Service Plan (Elastic Premium for Durable Functions) ===
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'EP1'
    tier: 'ElasticPremium'
    family: 'EP'
  }
  kind: 'elastic'
  properties: {
    maximumElasticWorkerCount: 3
    reserved: false // Windows
  }
}

// === Function App ===
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.4'
      netFrameworkVersion: 'v8.0'
      use32BitWorkerProcess: false
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=core.windows.net;AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=core.windows.net;AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: functionAppName
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME_VERSION'
          value: '7.4'
        }
        // === Provisioning Configuration ===
        {
          name: 'ENTRA_GROUP_OBJECT_ID'
          value: entraGroupObjectId
        }
        {
          name: 'BILLING_SCOPE'
          value: billingScope
        }
        {
          name: 'DEFAULT_LOCATION'
          value: location
        }
        {
          name: 'DEFAULT_WARNING_BUDGET'
          value: string(defaultWarningBudget)
        }
        {
          name: 'DEFAULT_HARD_LIMIT_BUDGET'
          value: string(defaultHardLimitBudget)
        }
        {
          name: 'DEFAULT_GRACE_PERIOD_DAYS'
          value: string(defaultGracePeriodDays)
        }
        {
          name: 'SYNC_SCHEDULE'
          value: syncSchedule
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
      ]
    }
  }
}

// === RBAC: Function App MI gets Owner on the subscription ===
// Owner is required to: create RGs, deploy resources, manage RBAC, create budgets
// This is scoped to the subscription, not the tenant.
resource functionAppOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().subscriptionId, functionApp.id, 'Owner')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8e3af657-a8ff-443c-a75c-2fe8c4bcb635')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Function App Owner for provisioning user environments'
  }
}

// === Outputs ===
output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output managedIdentityPrincipalId string = functionApp.identity.principalId
output managedIdentityClientId string = functionApp.identity.tenantId
output storageAccountName string = storageAccount.name
output appInsightsName string = appInsights.name
