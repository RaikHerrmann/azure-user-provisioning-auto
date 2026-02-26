// ============================================================================
// rbac.bicep - Role assignments for user within their resource group
// ============================================================================
// Assigns:
//   - Sandbox Contributor role to the user (scoped to resource group only)
//     This custom role is based on Contributor but additionally blocks
//     modification of cost enforcement resources (Automation, Budgets, etc.)
//   - Owner role to tenant admin for management operations
//
// Security notes:
//   - Sandbox Contributor at RG scope does NOT allow creating resource groups
//   - The role's notActions prevent tampering with cost management
//   - Azure Policy at subscription scope provides an additional guardrail
//   - The tenant admin keeps Owner for administrative overrides
// ============================================================================

// === Parameters ===
@description('Object ID of the user in Entra ID')
param userObjectId string

@description('Object ID of the tenant admin')
param tenantAdminObjectId string

@description('Full resource ID of the Sandbox Contributor custom role definition')
param sandboxContributorRoleId string

// === Variables ===
var ownerRoleId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'

// === Role Assignments ===

// User gets Sandbox Contributor ONLY on the resource group (not subscription)
// This means the user can:
//   - Create, manage, delete resources WITHIN this RG
//   - Use AI Foundry, compute, storage, etc.
// The user CANNOT:
//   - Create new resource groups (no subscription-level permissions)
//   - Access other resource groups
//   - Modify or delete the Automation Account, Budgets, or Action Groups
//   - Manage RBAC assignments (that requires Owner or User Access Administrator)
resource userSandboxAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, userObjectId, 'SandboxContributor')
  properties: {
    roleDefinitionId: sandboxContributorRoleId
    principalId: userObjectId
    principalType: 'User'
    description: 'Sandbox Contributor access for user sandbox environment - scoped to this RG only'
  }
}

// Tenant admin gets Owner on the resource group for full management
resource adminOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, tenantAdminObjectId, ownerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ownerRoleId)
    principalId: tenantAdminObjectId
    principalType: 'User'
    description: 'Owner access for tenant admin management'
  }
}

// === Outputs ===
output sandboxAssignmentId string = userSandboxAssignment.id
output adminOwnerAssignmentId string = adminOwnerAssignment.id
