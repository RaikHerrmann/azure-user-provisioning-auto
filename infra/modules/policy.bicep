// ============================================================================
// policy.bicep - Access restrictions and security guardrails
// ============================================================================
// Strategy:
//   We enforce resource group boundaries through THREE LAYERS:
//
//   Layer 1 (Custom RBAC Role - primary): User gets a "Sandbox Contributor"
//     custom role that is identical to built-in Contributor EXCEPT it also
//     blocks modification/deletion of cost management infrastructure:
//       - Automation Accounts (runbooks, schedules, variables, webhooks)
//       - Budgets (Microsoft.Consumption/budgets)
//       - Action Groups (Microsoft.Insights/actionGroups)
//     This prevents users from disabling cost enforcement.
//
//   Layer 2 (RBAC Scope): The custom role is assigned at RG scope ONLY.
//     => They have NO subscription-level role, so they CANNOT create RGs.
//     Without subscription-level permissions, the user cannot call the
//     RG create/delete APIs.
//
//   Layer 3 (Policy - guardrail): A subscription-scoped Azure Policy denies
//     creation of resource groups that don't match the naming convention.
//     This protects against future role changes that might accidentally
//     grant broader subscription-level permissions.
//
//   NOTE: Azure RBAC custom roles with notActions subtract permissions from
//   the same role's actions. They do NOT create a "deny" effect against
//   permissions granted by OTHER roles. This is why we use a SINGLE custom
//   role (not Contributor + deny overlay).
// ============================================================================

targetScope = 'subscription'

// === Parameters ===
@description('Object ID of the user to restrict')
param userObjectId string

@description('Name of the allowed (pre-created) resource group')
param allowedResourceGroupName string

@description('Object ID of the tenant admin (exempted from policy)')
param tenantAdminObjectId string

// === Variables ===
var uniqueSuffix = uniqueString(subscription().subscriptionId, userObjectId)
var subscriptionSuffix = uniqueString(subscription().subscriptionId)

// === Custom Role: Sandbox Contributor ===
// This role is identical to built-in Contributor but adds notActions that
// prevent users from tampering with cost enforcement infrastructure.
// One role definition is shared per subscription (not per user).
resource sandboxContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().subscriptionId, 'SandboxContributor')
  properties: {
    roleName: 'Sandbox Contributor - ${subscriptionSuffix}'
    description: 'Contributor role with protected cost management infrastructure. Cannot modify/delete Automation Accounts, Budgets, or Action Groups.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          '*'
        ]
        notActions: [
          // ── Standard Contributor exclusions ──
          'Microsoft.Authorization/*/Delete'
          'Microsoft.Authorization/*/Write'
          'Microsoft.Authorization/elevateAccess/Action'
          'Microsoft.Blueprint/blueprintAssignments/write'
          'Microsoft.Blueprint/blueprintAssignments/delete'
          'Microsoft.Compute/galleries/share/action'
          'Microsoft.Purview/consents/write'
          'Microsoft.Purview/consents/delete'
          // ── Sandbox: protect Automation Account (cost enforcement engine) ──
          'Microsoft.Automation/automationAccounts/delete'
          'Microsoft.Automation/automationAccounts/write'
          'Microsoft.Automation/automationAccounts/runbooks/*'
          'Microsoft.Automation/automationAccounts/schedules/*'
          'Microsoft.Automation/automationAccounts/variables/*'
          'Microsoft.Automation/automationAccounts/webhooks/*'
          'Microsoft.Automation/automationAccounts/jobSchedules/*'
          'Microsoft.Automation/automationAccounts/jobs/*'
          'Microsoft.Automation/automationAccounts/modules/*'
          'Microsoft.Automation/automationAccounts/powershell72Modules/*'
          'Microsoft.Automation/automationAccounts/connections/*'
          // ── Sandbox: protect Budgets ──
          'Microsoft.Consumption/budgets/delete'
          'Microsoft.Consumption/budgets/write'
          // ── Sandbox: protect Action Groups (email notifications) ──
          'Microsoft.Insights/actionGroups/delete'
          'Microsoft.Insights/actionGroups/write'
        ]
      }
    ]
    assignableScopes: [
      subscription().id
    ]
  }
}

// === Policy: Naming convention guardrail for resource groups ===
// Safety net: even if someone accidentally grants broader RBAC permissions,
// only resource groups matching "rg-*" can be created.
resource rgNamingPolicy 'Microsoft.Authorization/policyDefinitions@2021-06-01' = {
  name: 'rg-naming-convention-${uniqueSuffix}'
  properties: {
    policyType: 'Custom'
    mode: 'All'
    displayName: 'Enforce RG naming convention (rg-*) - ${allowedResourceGroupName}'
    description: 'Naming guardrail for sandbox ${allowedResourceGroupName}. Ensures resource groups follow the pattern rg-*.'
    metadata: {
      category: 'Resource Management'
      version: '1.0.0'
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Resources/subscriptions/resourceGroups'
          }
          {
            not: {
              field: 'name'
              like: 'rg-*'
            }
          }
        ]
      }
      then: {
        effect: 'deny'
      }
    }
  }
}

resource rgNamingPolicyAssignment 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name: 'rg-naming-${uniqueSuffix}'
  properties: {
    policyDefinitionId: rgNamingPolicy.id
    displayName: 'Enforce RG naming - ${allowedResourceGroupName}'
    description: 'Naming guardrail for sandbox ${allowedResourceGroupName}. Only rg-* resource groups allowed.'
    enforcementMode: 'Default'
    nonComplianceMessages: [
      {
        message: 'Resource group names must follow the pattern "rg-*". Please use your assigned resource group: ${allowedResourceGroupName}'
      }
    ]
  }
}

// === Outputs ===
output policyDefinitionId string = rgNamingPolicy.id
output policyAssignmentId string = rgNamingPolicyAssignment.id
output sandboxContributorRoleId string = sandboxContributorRole.id
