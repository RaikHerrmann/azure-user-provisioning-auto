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

function Test-UserProvisioned {
    <#
    .SYNOPSIS
        Check if a user already has a provisioned resource group.
    #>
    param([string]$UserPrincipalName)

    $rgName = Get-ResourceGroupName -UserPrincipalName $UserPrincipalName
    $rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
    return $null -ne $rg
}

Export-ModuleMember -Function Get-SanitizedUserName, Get-ResourceGroupName, Test-UserProvisioned
