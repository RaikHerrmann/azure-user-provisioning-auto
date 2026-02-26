// ============================================================================
// aiFoundry.bicep - Azure AI Foundry (Hub + Project) deployment
// ============================================================================
// Deploys:
//   - Azure Storage Account (for AI Foundry data)
//   - Azure Key Vault (for secrets management)
//   - Application Insights + Log Analytics (for monitoring)
//   - Azure AI Hub (the AI Foundry workspace)
//   - Azure AI Project (within the hub)
//   - RBAC for user on AI resources
// ============================================================================

// === Parameters ===
@description('Azure region for deployment')
param location string

@description('Unique suffix for resource naming')
param uniqueSuffix string

@description('Display name of the user')
param userDisplayName string

@description('Object ID of the user in Entra ID')
param userObjectId string

@description('Tags to apply to all resources')
param tags object

// === Variables ===
var storageAccountName = 'staifoundry${uniqueSuffix}'
var keyVaultName = 'kv-ai-${uniqueSuffix}'
var appInsightsName = 'appi-ai-${uniqueSuffix}'
var logAnalyticsName = 'log-ai-${uniqueSuffix}'
var aiHubName = 'aihub-${uniqueSuffix}'
var aiProjectName = 'aiproj-${uniqueSuffix}'

// Built-in role: Azure AI Developer
var aiDeveloperRoleId = '64702f94-c441-49e6-a78b-ef80e0188fee'
// Built-in role: Cognitive Services OpenAI User
var cogServicesOpenAIUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

// === Storage Account ===
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

// === Key Vault ===
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Enabled'
  }
}

// === Log Analytics Workspace ===
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
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
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// === Azure AI Hub (AI Foundry) ===
resource aiHub 'Microsoft.MachineLearningServices/workspaces@2024-10-01' = {
  name: aiHubName
  location: location
  tags: union(tags, {
    ProjectType: 'AI Foundry Hub'
  })
  kind: 'Hub'
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  properties: {
    friendlyName: 'AI Foundry Hub - ${userDisplayName}'
    description: 'AI Foundry Hub for ${userDisplayName} sandbox environment'
    storageAccount: storageAccount.id
    keyVault: keyVault.id
    applicationInsights: appInsights.id
    publicNetworkAccess: 'Enabled'
  }
}

// === Azure AI Project (within Hub) ===
resource aiProject 'Microsoft.MachineLearningServices/workspaces@2024-10-01' = {
  name: aiProjectName
  location: location
  tags: union(tags, {
    ProjectType: 'AI Foundry Project'
  })
  kind: 'Project'
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  properties: {
    friendlyName: 'AI Project - ${userDisplayName}'
    description: 'AI Foundry Project for ${userDisplayName}'
    hubResourceId: aiHub.id
    publicNetworkAccess: 'Enabled'
  }
}

// === RBAC: AI Developer role for user on the Hub ===
resource userAiDeveloperOnHub 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiHub.id, userObjectId, aiDeveloperRoleId)
  scope: aiHub
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aiDeveloperRoleId)
    principalId: userObjectId
    principalType: 'User'
    description: 'AI Developer access on AI Foundry Hub'
  }
}

// === RBAC: Cognitive Services OpenAI User for user on the Hub ===
resource userCogServicesOnHub 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiHub.id, userObjectId, cogServicesOpenAIUserRoleId)
  scope: aiHub
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cogServicesOpenAIUserRoleId)
    principalId: userObjectId
    principalType: 'User'
    description: 'Cognitive Services OpenAI User access on AI Foundry Hub'
  }
}

// === Outputs ===
output hubName string = aiHub.name
output hubId string = aiHub.id
output projectName string = aiProject.name
output projectId string = aiProject.id
output storageAccountName string = storageAccount.name
output keyVaultName string = keyVault.name
output appInsightsName string = appInsights.name
