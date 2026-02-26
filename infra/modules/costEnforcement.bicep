// ============================================================================
// costEnforcement.bicep - Azure Automation for cost limit enforcement
// ============================================================================
// Deploys:
//   - Azure Automation Account with System-Assigned Managed Identity
//   - RBAC: Contributor + User Access Administrator for the MI
//     (Contributor to stop/delete resources, UAA to change user RBAC)
//   - Runbook: Set user to read-only when $20 limit is hit
//   - Runbook: Delete resources after grace period
//   - Automation Variables for runbook configuration
//   - Webhook for budget action group integration
// ============================================================================

// === Parameters ===
@description('Azure region')
param location string

@description('Unique suffix for naming')
param uniqueSuffix string

@description('User Object ID')
param userObjectId string

@description('User email')
param userEmail string

@description('User display name')
param userDisplayName string

@description('Resource group name to manage')
param resourceGroupName string

@description('Subscription ID')
param subscriptionId string

@description('Grace period days before deletion')
param gracePeriodDays int

@description('Hard limit threshold for reference')
param hardLimitThreshold int

@description('Tags')
param tags object

@description('Deployment timestamp for scheduling (do not set manually)')
param deploymentTime string = utcNow('yyyy-MM-ddT06:00:00Z')

// === Variables ===
var automationAccountName = 'aa-cost-${uniqueSuffix}'
var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
// User Access Administrator - required to modify RBAC assignments
var userAccessAdminRoleId = '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9'

// === Automation Account ===
resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
    disableLocalAuth: false
    encryption: {
      keySource: 'Microsoft.Automation'
    }
  }
}

// === PowerShell 7.2 Modules (required by runbooks) ===
// Only Az.Accounts and Az.Resources are pre-installed in the PS 7.2 runtime.
// All other Az modules must be explicitly imported.
resource azComputeModule 'Microsoft.Automation/automationAccounts/powershell72Modules@2023-11-01' = {
  parent: automationAccount
  name: 'Az.Compute'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Az.Compute'
    }
  }
}

resource azWebsitesModule 'Microsoft.Automation/automationAccounts/powershell72Modules@2023-11-01' = {
  parent: automationAccount
  name: 'Az.Websites'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Az.Websites'
    }
  }
}

resource azMonitorModule 'Microsoft.Automation/automationAccounts/powershell72Modules@2023-11-01' = {
  parent: automationAccount
  name: 'Az.Monitor'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Az.Monitor'
    }
  }
}

resource azFunctionsModule 'Microsoft.Automation/automationAccounts/powershell72Modules@2023-11-01' = {
  parent: automationAccount
  name: 'Az.Functions'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Az.Functions'
    }
  }
}

resource azMLModule 'Microsoft.Automation/automationAccounts/powershell72Modules@2023-11-01' = {
  parent: automationAccount
  name: 'Az.MachineLearningServices'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Az.MachineLearningServices'
    }
  }
}

// === RBAC: Automation MI gets Contributor on the RG ===
// Needed to: stop VMs/WebApps, delete resources, manage deployments
resource automationContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, automationAccount.id, contributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Automation Account Contributor for stopping/deleting resources'
  }
}

// === RBAC: Automation MI gets User Access Administrator on the RG ===
// Needed to: remove Contributor from user, assign Reader to user
// Without this, the runbook CANNOT change RBAC assignments!
resource automationUserAccessAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, automationAccount.id, userAccessAdminRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', userAccessAdminRoleId)
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Automation Account User Access Admin for RBAC enforcement (swap Contributor to Reader)'
  }
}

// === Runbook: Cost Enforcement (Main Orchestrator) ===
resource costEnforcementRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Invoke-CostEnforcement'
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    description: 'Main cost enforcement runbook - sets read-only, stops resources, schedules deletion'
    logProgress: true
    logVerbose: true
  }
}

// === Runbook: Grace Period Cleanup ===
resource cleanupRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Invoke-GracePeriodCleanup'
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    description: 'Deletes all resources after grace period expires'
    logProgress: true
    logVerbose: true
  }
}

// === Automation Variables (used by runbooks) ===
resource userObjectIdVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'UserObjectId'
  properties: {
    value: '"${userObjectId}"'
    isEncrypted: false
    description: 'Object ID of the user to manage'
  }
}

resource userEmailVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'UserEmail'
  properties: {
    value: '"${userEmail}"'
    isEncrypted: false
    description: 'Email of the user for notifications'
  }
}

resource userDisplayNameVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'UserDisplayName'
  properties: {
    value: '"${userDisplayName}"'
    isEncrypted: false
    description: 'Display name of the user'
  }
}

resource rgNameVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'ResourceGroupName'
  properties: {
    value: '"${resourceGroupName}"'
    isEncrypted: false
    description: 'Resource group to manage'
  }
}

resource subscriptionIdVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'SubscriptionId'
  properties: {
    value: '"${subscriptionId}"'
    isEncrypted: false
    description: 'Subscription ID'
  }
}

resource gracePeriodVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'GracePeriodDays'
  properties: {
    value: '"${gracePeriodDays}"'
    isEncrypted: false
    description: 'Grace period in days before resource deletion'
  }
}

resource hardLimitVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'HardLimitThreshold'
  properties: {
    value: '"${hardLimitThreshold}"'
    isEncrypted: false
    description: 'Hard budget limit in USD'
  }
}

resource contributorRoleIdVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'ContributorRoleId'
  properties: {
    value: '"${contributorRoleId}"'
    isEncrypted: false
    description: 'Contributor role definition ID'
  }
}

resource readerRoleIdVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'ReaderRoleId'
  properties: {
    value: '"${readerRoleId}"'
    isEncrypted: false
    description: 'Reader role definition ID'
  }
}

// === Outputs ===
output automationAccountName string = automationAccount.name
output automationAccountId string = automationAccount.id
output automationPrincipalId string = automationAccount.identity.principalId
output costEnforcementRunbookName string = costEnforcementRunbook.name
output cleanupRunbookName string = cleanupRunbook.name

// === Schedule: Daily cost check (backup enforcement) ===
// Runs every day at 06:00 UTC to check current spend.
// If the budget runbook webhook fails or budget notification is delayed,
// this schedule ensures enforcement still happens within 24 hours.
resource dailyCostCheckSchedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name: 'DailyCostCheck'
  properties: {
    frequency: 'Day'
    interval: 1
    startTime: dateTimeAdd(deploymentTime, 'P1D')
    timeZone: 'Etc/UTC'
    description: 'Daily cost check - backup enforcement if budget notification is missed'
  }
}

resource dailyCostCheckLink 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = {
  parent: automationAccount
  name: guid(automationAccount.id, dailyCostCheckSchedule.id, costEnforcementRunbook.id)
  properties: {
    schedule: {
      name: dailyCostCheckSchedule.name
    }
    runbook: {
      name: costEnforcementRunbook.name
    }
  }
}
