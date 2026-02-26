// ============================================================================
// userEnvironment.bicep - Per-user environment orchestrator
// ============================================================================
// Adapted from the batch solution's main.bicep for event-driven use.
// This template deploys at SUBSCRIPTION scope and creates:
//   1. A resource group for the user
//   2. RBAC role assignments (Sandbox Contributor scoped to RG)
//   3. Azure Policy for naming convention guardrails
//   4. Azure AI Foundry (Hub + Project) with dependencies
//   5. Cost management budgets ($15 warning, $20 enforcement)
//   6. Azure Automation for cost enforcement actions
//
// Called by the Azure Function's DeployEnvironment activity.
// ============================================================================

targetScope = 'subscription'

// === Parameters ===
@description('The user principal name (UPN) of the user')
param userPrincipalName string

@description('Display name of the user')
param userDisplayName string

@description('Email address for notifications')
param userEmail string

@description('Object ID of the user in Entra ID')
param userObjectId string

@description('Azure region for all resources')
@allowed([
  'eastus'
  'eastus2'
  'westus'
  'westus2'
  'westus3'
  'centralus'
  'northeurope'
  'westeurope'
  'swedencentral'
  'uksouth'
  'southeastasia'
  'australiaeast'
  'canadacentral'
  'japaneast'
])
param location string = 'swedencentral'

@description('Department for tagging')
param department string = ''

@description('Cost center for tagging')
param costCenter string = ''

@description('Warning budget threshold in USD')
param warningBudgetThreshold int = 15

@description('Hard limit budget threshold in USD')
param hardLimitBudgetThreshold int = 20

@description('Grace period in days before resource deletion')
param gracePeriodDays int = 5

@description('Object ID of the provisioning service principal (Function App MI)')
param provisioningPrincipalId string

@description('Budget start date in YYYY-MM-01 format')
param budgetStartDate string

// === Variables ===
var userNameSanitized = toLower(replace(replace(userPrincipalName, '@', '-'), '.', '-'))
var resourceGroupName = 'rg-${userNameSanitized}'
var uniqueSuffix = uniqueString(subscription().subscriptionId, userPrincipalName)

var commonTags = {
  Environment: 'UserSandbox'
  ManagedBy: 'EventDrivenProvisioning'
  User: userPrincipalName
  Department: department
  CostCenter: costCenter
  CreatedDate: budgetStartDate
}

// === Resource Group ===
resource defaultResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: commonTags
}

// === RBAC ===
module rbacAssignment 'rbac.bicep' = {
  name: 'rbac-${uniqueSuffix}'
  scope: defaultResourceGroup
  params: {
    userObjectId: userObjectId
    tenantAdminObjectId: provisioningPrincipalId
    sandboxContributorRoleId: denyRgPolicy.outputs.sandboxContributorRoleId
  }
}

// === Policy ===
module denyRgPolicy 'policy.bicep' = {
  name: 'policy-deny-rg-${uniqueSuffix}'
  params: {
    userObjectId: userObjectId
    allowedResourceGroupName: resourceGroupName
    tenantAdminObjectId: provisioningPrincipalId
  }
}

// === AI Foundry ===
module aiFoundry 'aiFoundry.bicep' = {
  name: 'ai-foundry-${uniqueSuffix}'
  scope: defaultResourceGroup
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    userDisplayName: userDisplayName
    userObjectId: userObjectId
    tags: commonTags
  }
}

// === Cost Enforcement Automation ===
module costEnforcement 'costEnforcement.bicep' = {
  name: 'cost-enforce-${uniqueSuffix}'
  scope: defaultResourceGroup
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    userObjectId: userObjectId
    userEmail: userEmail
    userDisplayName: userDisplayName
    resourceGroupName: resourceGroupName
    subscriptionId: subscription().subscriptionId
    gracePeriodDays: gracePeriodDays
    hardLimitThreshold: hardLimitBudgetThreshold
    tags: commonTags
  }
}

// === Budgets ===
module costManagement 'budget.bicep' = {
  name: 'cost-mgmt-${uniqueSuffix}'
  scope: defaultResourceGroup
  params: {
    uniqueSuffix: uniqueSuffix
    userEmail: userEmail
    userDisplayName: userDisplayName
    warningThreshold: warningBudgetThreshold
    hardLimitThreshold: hardLimitBudgetThreshold
    budgetStartDate: budgetStartDate
    tags: commonTags
  }
}

// === Outputs ===
output resourceGroupName string = defaultResourceGroup.name
output resourceGroupId string = defaultResourceGroup.id
output aiFoundryHubName string = aiFoundry.outputs.hubName
output aiFoundryProjectName string = aiFoundry.outputs.projectName
output budgetName string = costManagement.outputs.budgetName
output automationAccountName string = costEnforcement.outputs.automationAccountName
