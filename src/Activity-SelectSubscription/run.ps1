<#
.SYNOPSIS
    Activity: Select a target subscription with available resource group capacity.

.DESCRIPTION
    Instead of creating a new subscription per user, this activity selects an existing
    subscription from a configured list (TARGET_SUBSCRIPTION_IDS) that still has room
    for more resource groups.

    Azure limits ~980 resource groups per subscription. The configurable limit
    MAX_RGS_PER_SUBSCRIPTION (default: 950) provides headroom.

    If a subscriptionId is already provided in the input (e.g. from the API caller),
    it validates that subscription has capacity and returns it directly.
#>
param($input)

$upn = $input.userPrincipalName
$requestedSubscriptionId = $input.subscriptionId

# Get configuration
$targetSubscriptionIds = ($env:TARGET_SUBSCRIPTION_IDS -split '[,;\s]+') | Where-Object { $_ -ne '' }
$maxRgsPerSubscription = if ($env:MAX_RGS_PER_SUBSCRIPTION) { [int]$env:MAX_RGS_PER_SUBSCRIPTION } else { 950 }

Write-Host "Selecting subscription for: $upn (max RGs per sub: $maxRgsPerSubscription)"

# === If a specific subscription was requested, validate and use it ===
if ($requestedSubscriptionId) {
    Write-Host "Caller requested subscription: $requestedSubscriptionId"
    try {
        Set-AzContext -SubscriptionId $requestedSubscriptionId -ErrorAction Stop
        $existingRgs = @(Get-AzResourceGroup -ErrorAction Stop)
        $rgCount = $existingRgs.Count

        if ($rgCount -ge $maxRgsPerSubscription) {
            Write-Warning "Requested subscription $requestedSubscriptionId has $rgCount RGs (limit: $maxRgsPerSubscription), at capacity."
            return @{
                subscriptionId = $null
                error          = "Requested subscription is at resource group capacity ($rgCount/$maxRgsPerSubscription)."
            }
        }

        Write-Host "Requested subscription $requestedSubscriptionId has capacity ($rgCount/$maxRgsPerSubscription RGs)."
        return @{
            subscriptionId = $requestedSubscriptionId
            rgCount        = $rgCount
        }
    }
    catch {
        Write-Warning "Cannot access requested subscription $requestedSubscriptionId : $_"
        return @{ subscriptionId = $null; error = "Cannot access requested subscription: $_" }
    }
}

# === Auto-select from configured target subscriptions ===
if (-not $targetSubscriptionIds -or $targetSubscriptionIds.Count -eq 0) {
    # Fallback: use the current subscription context
    $currentSub = (Get-AzContext).Subscription.Id
    if ($currentSub) {
        Write-Host "No TARGET_SUBSCRIPTION_IDS configured. Using current context subscription: $currentSub"
        $targetSubscriptionIds = @($currentSub)
    }
    else {
        Write-Warning "No target subscriptions configured and no current subscription context."
        return @{ subscriptionId = $null; error = 'No target subscriptions configured (set TARGET_SUBSCRIPTION_IDS).' }
    }
}

Write-Host "Checking $($targetSubscriptionIds.Count) target subscription(s) for available capacity..."

foreach ($subId in $targetSubscriptionIds) {
    try {
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
        $existingRgs = @(Get-AzResourceGroup -ErrorAction Stop)
        $rgCount = $existingRgs.Count

        Write-Host "  Subscription $subId : $rgCount RGs (limit: $maxRgsPerSubscription)"

        if ($rgCount -lt $maxRgsPerSubscription) {
            Write-Host "Selected subscription: $subId ($rgCount/$maxRgsPerSubscription RGs used)"
            return @{
                subscriptionId = $subId
                rgCount        = $rgCount
            }
        }
        else {
            Write-Host "  Subscription $subId is at capacity ($rgCount >= $maxRgsPerSubscription). Trying next..."
        }
    }
    catch {
        Write-Warning "  Cannot access subscription $subId : $_ — skipping."
    }
}

# All subscriptions are full
Write-Warning "All configured subscriptions are at resource group capacity."
return @{
    subscriptionId = $null
    error          = "All configured subscriptions have reached the maximum resource group limit ($maxRgsPerSubscription). Add more subscriptions to TARGET_SUBSCRIPTION_IDS."
}
