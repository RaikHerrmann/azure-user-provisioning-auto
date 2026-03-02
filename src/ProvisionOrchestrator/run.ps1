<#
.SYNOPSIS
    Durable Orchestrator — Coordinates the multi-step provisioning workflow.

.DESCRIPTION
    Orchestration steps:
      1. Resolve user in Entra ID (get Object ID)
      2. Select a target subscription with available RG capacity
      3. Deploy Bicep environment (RG, RBAC, AI Foundry, Budget, Automation)
      4. Configure runbooks (upload scripts, wire webhooks)

    Each step is an Activity Function with automatic retry on failure.
    The orchestrator is replay-safe (idempotent, deterministic).
#>
param($Context)

$input = $Context.Input
$retryOptions = New-DurableRetryOptions -FirstRetryInterval (New-TimeSpan -Seconds 10) -MaxNumberOfAttempts 3

Write-Host "Orchestrator started for: $($input.userPrincipalName)"

# === Step 1: Resolve User in Entra ID ===
$resolvedUser = Invoke-DurableActivity -FunctionName 'Activity-ResolveUser' -Input $input -RetryOptions $retryOptions
if (-not $resolvedUser -or -not $resolvedUser.objectId) {
    Write-Host "FAILED: Could not resolve user $($input.userPrincipalName) in Entra ID."
    return @{
        status  = 'Failed'
        user    = $input.userPrincipalName
        reason  = 'User not found in Entra ID'
        step    = 'ResolveUser'
    }
}

$input.userObjectId = $resolvedUser.objectId
Write-Host "User resolved: $($input.userPrincipalName) -> $($resolvedUser.objectId)"

# === Step 2: Select Subscription (with available RG capacity) ===
$subscriptionResult = Invoke-DurableActivity -FunctionName 'Activity-SelectSubscription' -Input $input -RetryOptions $retryOptions
if ($subscriptionResult -and $subscriptionResult.subscriptionId) {
    $input.subscriptionId = $subscriptionResult.subscriptionId
    Write-Host "Subscription selected: $($subscriptionResult.subscriptionId) ($($subscriptionResult.rgCount) RGs in use)"
} else {
    $errorMsg = if ($subscriptionResult.error) { $subscriptionResult.error } else { 'No subscription with available RG capacity' }
    Write-Host "FAILED: Could not select subscription for $($input.userPrincipalName). $errorMsg"
    return @{
        status  = 'Failed'
        user    = $input.userPrincipalName
        reason  = $errorMsg
        step    = 'SelectSubscription'
    }
}

# === Step 3: Deploy Bicep Environment ===
$deployResult = Invoke-DurableActivity -FunctionName 'Activity-DeployEnvironment' -Input $input -RetryOptions $retryOptions
if (-not $deployResult -or $deployResult.status -ne 'Succeeded') {
    Write-Host "FAILED: Bicep deployment failed for $($input.userPrincipalName)."
    return @{
        status  = 'Failed'
        user    = $input.userPrincipalName
        reason  = "Deployment failed: $($deployResult.error)"
        step    = 'DeployEnvironment'
    }
}

Write-Host "Deployment succeeded: RG=$($deployResult.resourceGroupName)"

# === Step 4: Configure Runbooks ===
$configResult = Invoke-DurableActivity -FunctionName 'Activity-ConfigureRunbooks' -Input @{
    subscriptionId        = $input.subscriptionId
    resourceGroupName     = $deployResult.resourceGroupName
    automationAccountName = $deployResult.automationAccountName
    budgetName            = $deployResult.budgetName
} -RetryOptions $retryOptions

Write-Host "Runbook configuration: $($configResult.status)"

# === Final Result ===
return @{
    status                = 'Succeeded'
    user                  = $input.userPrincipalName
    subscriptionId        = $input.subscriptionId
    resourceGroupName     = $deployResult.resourceGroupName
    aiFoundryHubName      = $deployResult.aiFoundryHubName
    aiFoundryProjectName  = $deployResult.aiFoundryProjectName
    budgetName            = $deployResult.budgetName
    automationAccountName = $deployResult.automationAccountName
    runbookStatus         = $configResult.status
}
