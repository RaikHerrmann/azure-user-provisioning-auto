// ============================================================================
// main.bicep - Platform infrastructure for event-driven user provisioning
// ============================================================================
// Deploys:
//   1. Azure Function App (PowerShell, Durable Functions) on Premium plan
//   2. Storage Account (Function App state + Durable Functions task hub)
//   3. Application Insights (monitoring)
//   4. Log Analytics Workspace
//   5. Managed Identity with required permissions
//   6. Template Spec for per-user environment deployment
//
// This is deployed ONCE by the admin (or CI/CD). The Function App then
// handles all per-user provisioning automatically via triggers.
// ============================================================================

targetScope = 'subscription'

// === Parameters ===
@description('Azure region for platform resources')
@allowed([
  'eastus'
  'eastus2'
  'westus2'
  'swedencentral'
  'westeurope'
  'northeurope'
  'uksouth'
  'australiaeast'
  'canadacentral'
  'japaneast'
])
param location string = 'swedencentral'

@description('Name prefix for all platform resources')
param namePrefix string = 'userprov'

@description('Entra ID security group Object ID to sync for auto-provisioning (optional)')
param entraGroupObjectId string = ''

@description('Comma-separated list of target subscription IDs for deploying user resource groups')
param targetSubscriptionIds string = ''

@description('Maximum number of resource groups per subscription before overflow to next (Azure limit: ~980)')
param maxRgsPerSubscription int = 950

@description('API key for webhook authentication (callers must send X-API-Key header). Leave empty to rely only on function keys.')
@secure()
param webhookApiKey string = ''

@description('Default warning budget threshold (USD)')
param defaultWarningBudget int = 15

@description('Default hard limit budget threshold (USD)')
param defaultHardLimitBudget int = 20

@description('Default grace period before deletion (days)')
param defaultGracePeriodDays int = 5

@description('Timer schedule for Entra ID group sync (NCRONTAB format)')
param syncSchedule string = '0 */10 * * * *'

// === Variables ===
var uniqueSuffix = uniqueString(subscription().subscriptionId, namePrefix)
var rgName = 'rg-${namePrefix}-platform'

// === Resource Group ===
resource platformRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
  tags: {
    Purpose: 'UserProvisioningPlatform'
    ManagedBy: 'IaC-Automation'
  }
}

// === Function App Module ===
module functionApp 'modules/functionApp.bicep' = {
  name: 'function-app-${uniqueSuffix}'
  scope: platformRg
  params: {
    location: location
    namePrefix: namePrefix
    uniqueSuffix: uniqueSuffix
    entraGroupObjectId: entraGroupObjectId
    targetSubscriptionIds: targetSubscriptionIds
    maxRgsPerSubscription: maxRgsPerSubscription
    webhookApiKey: webhookApiKey
    defaultWarningBudget: defaultWarningBudget
    defaultHardLimitBudget: defaultHardLimitBudget
    defaultGracePeriodDays: defaultGracePeriodDays
    syncSchedule: syncSchedule
  }
}

// === Outputs ===
output platformResourceGroupName string = platformRg.name
output functionAppName string = functionApp.outputs.functionAppName
output functionAppUrl string = functionApp.outputs.functionAppUrl
output managedIdentityPrincipalId string = functionApp.outputs.managedIdentityPrincipalId
output managedIdentityClientId string = functionApp.outputs.managedIdentityClientId
