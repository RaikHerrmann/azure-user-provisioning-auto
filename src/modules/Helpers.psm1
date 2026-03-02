<#
.SYNOPSIS
    Shared helper functions for provisioning operations.
#>

function Get-SanitizedUserName {
    param([string]$UserPrincipalName)
    return $UserPrincipalName.ToLower() -replace '@', '-' -replace '\.', '-'
}

function Get-ResourceGroupName {
    param([string]$UserPrincipalName)
    return "rg-$(Get-SanitizedUserName -UserPrincipalName $UserPrincipalName)"
}

function Get-TargetSubscriptionIds {
    <#
    .SYNOPSIS
        Returns the list of configured target subscription IDs.
    #>
    $ids = ($env:TARGET_SUBSCRIPTION_IDS -split '[,;\s]+') | Where-Object { $_ -ne '' }
    if (-not $ids -or $ids.Count -eq 0) {
        $currentSub = (Get-AzContext).Subscription.Id
        if ($currentSub) { return @($currentSub) }
        return @()
    }
    return $ids
}

function Find-UserResourceGroup {
    <#
    .SYNOPSIS
        Find a user's resource group across all configured target subscriptions.
    .OUTPUTS
        Hashtable with subscriptionId and resourceGroupName, or $null if not found.
    #>
    param([string]$UserPrincipalName)

    $rgName = Get-ResourceGroupName -UserPrincipalName $UserPrincipalName
    $subscriptionIds = Get-TargetSubscriptionIds

    foreach ($subId in $subscriptionIds) {
        try {
            Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
            $rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
            if ($rg) {
                return @{
                    subscriptionId    = $subId
                    resourceGroupName = $rgName
                }
            }
        }
        catch {
            # Skip inaccessible subscriptions
        }
    }
    return $null
}

function Test-UserProvisioned {
    <#
    .SYNOPSIS
        Check if a user already has a provisioned resource group in any target subscription.
    #>
    param([string]$UserPrincipalName)

    $result = Find-UserResourceGroup -UserPrincipalName $UserPrincipalName
    return $null -ne $result
}

Export-ModuleMember -Function Get-SanitizedUserName, Get-ResourceGroupName, Get-TargetSubscriptionIds, Find-UserResourceGroup, Test-UserProvisioned
