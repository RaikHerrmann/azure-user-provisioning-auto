// ============================================================================
// budget.bicep - Cost Management Budgets and Action Groups
// ============================================================================
// Creates:
//   - Action Group for warning notifications (email at $15)
//   - Action Group for hard limit enforcement (email + automation runbook at $20)
//   - Budget with thresholds:
//       75% actual   = $15 warning email
//       90% forecast = proactive warning
//       100% actual  = $20 hard enforcement
//   - The budget amount is set to $20 (hardLimitThreshold)
// ============================================================================

// === Parameters ===
@description('Unique suffix for resource naming')
param uniqueSuffix string

@description('User email for notifications')
param userEmail string

@description('User display name')
param userDisplayName string

@description('Warning threshold in USD')
param warningThreshold int

@description('Hard limit threshold in USD')
param hardLimitThreshold int

@description('Budget start date (YYYY-MM-01 format)')
param budgetStartDate string

@description('Tags to apply to resources')
param tags object

// === Variables ===
var actionGroupWarningName = 'ag-warning-${uniqueSuffix}'
var actionGroupEnforceName = 'ag-enforce-${uniqueSuffix}'
var budgetName = 'budget-${uniqueSuffix}'

// Calculate warning percentage relative to hard limit
// e.g., $15 warning / $20 hard limit = 75%
var warningPercentage = (warningThreshold * 100) / hardLimitThreshold

// === Action Group: Warning Email ===
resource warningActionGroup 'Microsoft.Insights/actionGroups@2023-09-01-preview' = {
  name: actionGroupWarningName
  location: 'Global'
  tags: tags
  properties: {
    groupShortName: 'CostWarn'
    enabled: true
    emailReceivers: [
      {
        name: 'UserWarning'
        emailAddress: userEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// === Action Group: Hard Limit Enforcement ===
// This action group emails the user when the hard limit is reached.
// The automation runbook receiver is wired post-deployment by the script
// (webhooks cannot be created declaratively in Bicep due to URI security).
// As backup, a daily schedule on the Automation Account also checks costs.
resource enforceActionGroup 'Microsoft.Insights/actionGroups@2023-09-01-preview' = {
  name: actionGroupEnforceName
  location: 'Global'
  tags: tags
  properties: {
    groupShortName: 'CostEnf'
    enabled: true
    emailReceivers: [
      {
        name: 'UserEnforcement'
        emailAddress: userEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// === Budget ===
// Scoped to resource group - monitors all costs within the user's RG
resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: budgetName
  properties: {
    timePeriod: {
      startDate: budgetStartDate
    }
    timeGrain: 'Monthly'
    amount: hardLimitThreshold
    category: 'Cost'
    notifications: {
      // Warning notification at $15 (75% of $20)
      warningNotification: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: warningPercentage
        thresholdType: 'Actual'
        contactEmails: [
          userEmail
        ]
        contactGroups: [
          warningActionGroup.id
        ]
        locale: 'en-us'
      }
      // Hard limit notification at $20 (100%)
      hardLimitNotification: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Actual'
        contactEmails: [
          userEmail
        ]
        contactGroups: [
          enforceActionGroup.id
        ]
        locale: 'en-us'
      }
      // Forecasted warning at 90%
      forecastWarning: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 90
        thresholdType: 'Forecasted'
        contactEmails: [
          userEmail
        ]
        contactGroups: [
          warningActionGroup.id
        ]
        locale: 'en-us'
      }
    }
    // Budget is deployed at RG scope, so it automatically filters to this RG.
    // No additional dimension filter needed.
  }
}

// === Outputs ===
output budgetName string = budget.name
output warningActionGroupId string = warningActionGroup.id
output enforceActionGroupId string = enforceActionGroup.id
