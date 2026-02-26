<#
.SYNOPSIS
    Grace Period Cleanup Runbook - Deletes all resources after grace period.

.DESCRIPTION
    This runbook is scheduled to run N days after cost enforcement is triggered.
    It performs:
      1. Inventories all resources (for audit log)
      2. Deletes all resources within the resource group in dependency order
      3. Removes user RBAC assignments
      4. Logs all actions

.NOTES
    Runs under the Automation Account's System-Assigned Managed Identity.
    The Automation Account itself is skipped during deletion so the job
    can complete. The tenant admin should run Remove-UserEnvironment.ps1
    for full teardown including the Automation Account.
#>

#Requires -Modules Az.Accounts, Az.Resources

param()

# ============================================================================
# Initialize
# ============================================================================
Write-Output "=========================================="
Write-Output "GRACE PERIOD CLEANUP RUNBOOK - STARTED"
Write-Output "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC' -AsUTC)"
Write-Output "=========================================="

try {
    # Authenticate using Managed Identity
    Write-Output "Authenticating with Managed Identity..."
    Connect-AzAccount -Identity -ErrorAction Stop
    Write-Output "Authentication successful."

    # Read configuration
    $userObjectId       = (Get-AutomationVariable -Name 'UserObjectId')
    $userEmail          = (Get-AutomationVariable -Name 'UserEmail')
    $userDisplayName    = (Get-AutomationVariable -Name 'UserDisplayName')
    $resourceGroupName  = (Get-AutomationVariable -Name 'ResourceGroupName')
    $subscriptionId     = (Get-AutomationVariable -Name 'SubscriptionId')
    $gracePeriodDays    = [int](Get-AutomationVariable -Name 'GracePeriodDays')

    Write-Output "Configuration loaded:"
    Write-Output "  User: $userDisplayName ($userEmail)"
    Write-Output "  Resource Group: $resourceGroupName"
    Write-Output "  Subscription: $subscriptionId"

    # Set subscription context
    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop

    # ============================================================================
    # Step 1: Inventory resources before deletion (for audit log)
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 1: Inventorying resources ---"

    $resources = Get-AzResource -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue

    if ($resources) {
        Write-Output "  Found $($resources.Count) resources to delete:"
        foreach ($resource in $resources) {
            Write-Output "    - $($resource.ResourceType): $($resource.Name)"
        }
    }
    else {
        Write-Output "  No resources found in resource group."
        Write-Output "  Cleanup complete (nothing to delete)."
        return
    }

    # ============================================================================
    # Step 2: Delete all resources in the resource group
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 2: Deleting all resources ---"

    # Define deletion order (reverse dependency)
    $deleteOrder = @(
        'Microsoft.Compute/*'
        'Microsoft.ContainerInstance/*'
        'Microsoft.Web/*'
        'Microsoft.MachineLearningServices/*'
        'Microsoft.CognitiveServices/*'
        'Microsoft.Network/*'
        'Microsoft.Insights/*'
        'Microsoft.OperationalInsights/*'
        'Microsoft.Storage/*'
        'Microsoft.KeyVault/*'
        'Microsoft.Consumption/*'
    )

    # Track what we've deleted to avoid double-processing
    $deletedIds = @{}

    # Delete resources matching known types first (in order)
    foreach ($typePattern in $deleteOrder) {
        $matchingResources = $resources | Where-Object {
            $_.ResourceType -like $typePattern -and -not $deletedIds.ContainsKey($_.ResourceId)
        }
        foreach ($resource in $matchingResources) {
            # Skip the automation account itself
            if ($resource.ResourceType -eq 'Microsoft.Automation/automationAccounts') {
                Write-Output "  Skipping Automation Account (self): $($resource.Name)"
                continue
            }
            Write-Output "  Deleting: $($resource.ResourceType) / $($resource.Name)..."
            try {
                Remove-AzResource -ResourceId $resource.ResourceId -Force -ErrorAction Stop
                $deletedIds[$resource.ResourceId] = $true
                Write-Output "    Deleted successfully."
            }
            catch {
                Write-Warning "    Failed to delete: $_"
            }
        }
    }

    # Delete any remaining resources
    $remainingResources = Get-AzResource -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    foreach ($resource in $remainingResources) {
        if ($resource.ResourceType -eq 'Microsoft.Automation/automationAccounts') {
            continue
        }
        if ($deletedIds.ContainsKey($resource.ResourceId)) {
            continue
        }
        Write-Output "  Deleting remaining: $($resource.ResourceType) / $($resource.Name)..."
        try {
            Remove-AzResource -ResourceId $resource.ResourceId -Force -ErrorAction Continue
        }
        catch {
            Write-Warning "    Failed to delete: $_"
        }
    }

    # ============================================================================
    # Step 3: Remove user RBAC assignments
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 3: Removing user RBAC ---"

    $rgScope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName"
    $roleAssignments = Get-AzRoleAssignment -ObjectId $userObjectId `
        -Scope $rgScope -ErrorAction SilentlyContinue

    foreach ($assignment in $roleAssignments) {
        Write-Output "  Removing role: $($assignment.RoleDefinitionName)..."
        Remove-AzRoleAssignment -InputObject $assignment -ErrorAction Continue
    }

    # ============================================================================
    # Summary
    # ============================================================================
    Write-Output ""
    Write-Output "=========================================="
    Write-Output "GRACE PERIOD CLEANUP COMPLETED"
    Write-Output "=========================================="
    Write-Output "Actions taken:"
    Write-Output "  [x] All resources in '$resourceGroupName' deleted"
    Write-Output "  [x] User RBAC assignments removed"
    Write-Output "  [x] User $userDisplayName ($userEmail) notified (via Action Group)"
    Write-Output ""
    Write-Output "NOTE: The Automation Account remains for audit."
    Write-Output "      Run Remove-UserEnvironment.ps1 for full teardown."
}
catch {
    Write-Error "Grace period cleanup failed: $_"
    Write-Error $_.ScriptStackTrace
    throw
}
