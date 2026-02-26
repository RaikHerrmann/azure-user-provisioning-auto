<#
.SYNOPSIS
    Cost Enforcement Runbook - Triggered when budget hard limit ($20) is reached.

.DESCRIPTION
    This runbook is triggered by the Azure Budget Action Group when cost reaches
    the hard limit. It performs:
      1. Changes user RBAC from Contributor to Reader (read-only)
      2. Stops all running compute resources (VMs, App Services, etc.)
      3. Stops any AI/ML inference endpoints
      4. Schedules the grace period cleanup runbook to run after N days
      5. User is notified via the action group email (automatic)

.NOTES
    Runs under the Automation Account's System-Assigned Managed Identity.
    The MI MUST have both Contributor AND User Access Administrator roles
    on the resource group (Contributor alone cannot change RBAC).
#>

#Requires -Modules Az.Accounts, Az.Resources, Az.Compute, Az.Websites, Az.Functions, Az.Monitor, Az.MachineLearningServices

param(
    [Parameter(Mandatory = $false)]
    [object]$WebhookData
)

# ============================================================================
# Initialize
# ============================================================================
Write-Output "=========================================="
Write-Output "COST ENFORCEMENT RUNBOOK - STARTED"
Write-Output "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC' -AsUTC)"
Write-Output "=========================================="

try {
    # Authenticate using Managed Identity
    Write-Output "Authenticating with Managed Identity..."
    Connect-AzAccount -Identity -ErrorAction Stop
    Write-Output "Authentication successful."

    # Read configuration from Automation Variables
    $userObjectId       = (Get-AutomationVariable -Name 'UserObjectId')
    $userEmail          = (Get-AutomationVariable -Name 'UserEmail')
    $userDisplayName    = (Get-AutomationVariable -Name 'UserDisplayName')
    $resourceGroupName  = (Get-AutomationVariable -Name 'ResourceGroupName')
    $subscriptionId     = (Get-AutomationVariable -Name 'SubscriptionId')
    $gracePeriodDays    = [int](Get-AutomationVariable -Name 'GracePeriodDays')
    $hardLimitThreshold = (Get-AutomationVariable -Name 'HardLimitThreshold')
    $contributorRoleId  = (Get-AutomationVariable -Name 'ContributorRoleId')
    $readerRoleId       = (Get-AutomationVariable -Name 'ReaderRoleId')

    Write-Output "Configuration loaded:"
    Write-Output "  User: $userDisplayName ($userEmail)"
    Write-Output "  Resource Group: $resourceGroupName"
    Write-Output "  Subscription: $subscriptionId"
    Write-Output "  Grace Period: $gracePeriodDays days"
    Write-Output "  Hard Limit: `$$hardLimitThreshold"

    # Set subscription context
    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop

    # ============================================================================
    # Step 0: Check if enforcement is needed (for scheduled runs)
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 0: Checking current cost ---"

    # Check if user already has Reader (enforcement already applied)
    $rgScope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName"

    # Get ALL role assignments for the user (including child-resource scopes like AI Hub)
    $allUserAssignments = Get-AzRoleAssignment -ObjectId $userObjectId -ErrorAction SilentlyContinue |
        Where-Object { $_.Scope -like "$rgScope*" }

    $existingReaderAssignment = $allUserAssignments |
        Where-Object { $_.RoleDefinitionName -eq 'Reader' -and $_.Scope -eq $rgScope }

    # Any write role (Sandbox Contributor, Azure AI Developer, etc.) at RG or child scope
    $existingWriteAssignments = $allUserAssignments |
        Where-Object { $_.RoleDefinitionName -ne 'Reader' }

    if ($existingReaderAssignment -and -not $existingWriteAssignments) {
        Write-Output "  Enforcement already applied (user has Reader, no write roles). Skipping."
        return
    }

    # If this is a scheduled run (no WebhookData), check actual cost
    if (-not $WebhookData) {
        Write-Output "  Running as scheduled check. Querying current cost..."
        try {
            $startOfMonth = (Get-Date -Day 1).ToString('yyyy-MM-dd')
            $today = (Get-Date).ToString('yyyy-MM-dd')

            # Use Cost Management API via REST (more reliable than consumption cmdlets)
            $token = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com').Token
            $costUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
            $body = @{
                type = "ActualCost"
                timeframe = "Custom"
                timePeriod = @{
                    from = $startOfMonth
                    to = $today
                }
                dataset = @{
                    granularity = "None"
                    aggregation = @{
                        totalCost = @{
                            name = "Cost"
                            function = "Sum"
                        }
                    }
                }
            } | ConvertTo-Json -Depth 5

            $response = Invoke-RestMethod -Uri $costUri -Method POST -Body $body `
                -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
                -ErrorAction Stop

            $currentCost = 0
            if ($response.properties.rows -and $response.properties.rows.Count -gt 0) {
                $currentCost = [decimal]$response.properties.rows[0][0]
            }

            Write-Output "  Current month cost: `$$([math]::Round($currentCost, 2))"
            Write-Output "  Hard limit: `$$hardLimitThreshold"

            if ($currentCost -lt [decimal]$hardLimitThreshold) {
                Write-Output "  Cost is below threshold. No enforcement needed."
                return
            }
            Write-Output "  Cost EXCEEDS threshold! Proceeding with enforcement..."
        }
        catch {
            Write-Warning "  Could not query costs (data may be delayed): $_"
            Write-Output "  Skipping enforcement on this scheduled run (cannot confirm cost)."
            return
        }
    }
    else {
        Write-Output "  Triggered by webhook/budget notification. Proceeding with enforcement."
    }

    # ============================================================================
    # Step 1: Change user RBAC to Read-Only
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 1: Setting user to READ-ONLY ---"

    # Remove ALL write roles for the user (Sandbox Contributor at RG scope,
    # Azure AI Developer / Cognitive Services OpenAI User at child scopes, etc.)
    # Re-fetch in case assignments changed since Step 0
    $allUserAssignments = Get-AzRoleAssignment -ObjectId $userObjectId -ErrorAction SilentlyContinue |
        Where-Object { $_.Scope -like "$rgScope*" }
    $writeAssignments = $allUserAssignments |
        Where-Object { $_.RoleDefinitionName -ne 'Reader' }

    if ($writeAssignments) {
        foreach ($wa in $writeAssignments) {
            try {
                Remove-AzRoleAssignment -InputObject $wa -ErrorAction Stop
                Write-Output "  Removed '$($wa.RoleDefinitionName)' role from user (scope: $($wa.Scope))."
            }
            catch {
                Write-Warning "  Failed to remove '$($wa.RoleDefinitionName)': $_"
            }
        }
    }
    else {
        Write-Output "  No write roles found (may already be removed)."
    }

    # Assign Reader role at RG scope (idempotent - check first)
    $readerAssignment = $allUserAssignments |
        Where-Object { $_.RoleDefinitionName -eq 'Reader' -and $_.Scope -eq $rgScope }

    if (-not $readerAssignment) {
        New-AzRoleAssignment -ObjectId $userObjectId `
            -RoleDefinitionId $readerRoleId `
            -Scope $rgScope `
            -ErrorAction Stop
        Write-Output "  Assigned Reader role to user."
    }
    else {
        Write-Output "  Reader role already assigned."
    }

    # ============================================================================
    # Step 2: Stop all compute resources
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 2: Stopping all compute resources ---"

    # Stop VMs
    $vms = Get-AzVM -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    foreach ($vm in $vms) {
        Write-Output "  Stopping VM: $($vm.Name)..."
        Stop-AzVM -ResourceGroupName $resourceGroupName -Name $vm.Name -Force -NoWait -ErrorAction Continue
    }

    # Stop App Services / Web Apps
    $webApps = Get-AzWebApp -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    foreach ($app in $webApps) {
        Write-Output "  Stopping Web App: $($app.Name)..."
        Stop-AzWebApp -ResourceGroupName $resourceGroupName -Name $app.Name -ErrorAction Continue
    }

    # Stop Function Apps
    try {
        $funcApps = Get-AzFunctionApp -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
        foreach ($func in $funcApps) {
            Write-Output "  Stopping Function App: $($func.Name)..."
            Stop-AzFunctionApp -ResourceGroupName $resourceGroupName -Name $func.Name -Force -ErrorAction Continue
        }
    }
    catch {
        Write-Warning "  Could not enumerate Function Apps: $_"
    }

    # ============================================================================
    # Step 3: Disable AI/ML Online Endpoints (stop inference)
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 3: Disabling AI/ML endpoints ---"

    try {
        $workspaces = Get-AzMLWorkspace -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
        foreach ($ws in $workspaces) {
            $endpoints = Get-AzMLOnlineEndpoint -ResourceGroupName $resourceGroupName `
                -WorkspaceName $ws.Name -ErrorAction SilentlyContinue
            foreach ($ep in $endpoints) {
                Write-Output "  Disabling endpoint: $($ep.Name) in workspace $($ws.Name)..."
                $deployments = Get-AzMLOnlineDeployment -ResourceGroupName $resourceGroupName `
                    -WorkspaceName $ws.Name -EndpointName $ep.Name -ErrorAction SilentlyContinue
                foreach ($dep in $deployments) {
                    Write-Output "    Removing deployment $($dep.Name)..."
                    try {
                        Remove-AzMLOnlineDeployment -ResourceGroupName $resourceGroupName `
                            -WorkspaceName $ws.Name -EndpointName $ep.Name `
                            -Name $dep.Name -ErrorAction Continue
                    }
                    catch {
                        Write-Warning "    Failed to remove deployment: $_"
                    }
                }
            }
        }
    }
    catch {
        Write-Warning "  Could not process ML workspaces: $_"
    }

    # ============================================================================
    # Step 4: Schedule grace period cleanup
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 4: Scheduling grace period cleanup ---"

    $automationAccounts = Get-AzAutomationAccount -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    if ($automationAccounts -and $automationAccounts.Count -gt 0) {
        $automationAccountName = $automationAccounts[0].AutomationAccountName
        $scheduleName = "GracePeriodCleanup-$(Get-Date -Format 'yyyyMMddHHmm')"
        $cleanupDate = (Get-Date).AddDays($gracePeriodDays).ToUniversalTime()

        Write-Output "  Creating schedule '$scheduleName' for $cleanupDate UTC"

        # Create a one-time schedule
        New-AzAutomationSchedule -AutomationAccountName $automationAccountName `
            -ResourceGroupName $resourceGroupName `
            -Name $scheduleName `
            -StartTime $cleanupDate `
            -OneTime `
            -TimeZone "Etc/UTC" `
            -ErrorAction Stop

        # Link the cleanup runbook to the schedule
        Register-AzAutomationScheduledRunbook -AutomationAccountName $automationAccountName `
            -ResourceGroupName $resourceGroupName `
            -RunbookName "Invoke-GracePeriodCleanup" `
            -ScheduleName $scheduleName `
            -ErrorAction Stop

        Write-Output "  Cleanup scheduled for $cleanupDate UTC ($gracePeriodDays days from now)."
    }
    else {
        Write-Warning "  No Automation Account found - cannot schedule cleanup."
    }

    # ============================================================================
    # Summary
    # ============================================================================
    Write-Output ""
    Write-Output "=========================================="
    Write-Output "COST ENFORCEMENT COMPLETED SUCCESSFULLY"
    Write-Output "=========================================="
    Write-Output "Actions taken:"
    Write-Output "  [x] User RBAC changed to Reader (read-only)"
    Write-Output "  [x] All compute resources stopped"
    Write-Output "  [x] AI/ML endpoints disabled"
    Write-Output "  [x] Cleanup scheduled after $gracePeriodDays days"
    Write-Output "  [x] User notified via Action Group email"
}
catch {
    Write-Error "Cost enforcement failed: $_"
    Write-Error $_.ScriptStackTrace
    throw
}
