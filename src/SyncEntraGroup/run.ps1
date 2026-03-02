<#
.SYNOPSIS
    Timer Trigger — Syncs an Entra ID security group and provisions new members.

.DESCRIPTION
    Runs on a configurable schedule (default: every 10 minutes).
    Checks the configured Entra ID security group for members.
    For each member that does NOT yet have a provisioned resource group,
    starts the provisioning orchestrator.

    This is the "zero-touch" trigger: an admin simply adds a user to the
    Entra ID group, and their sandbox environment is created automatically.

    The function tracks provisioned users via Azure Table Storage to avoid
    re-provisioning existing users.
#>
param($Timer, $TriggerMetadata)

Import-Module "$PSScriptRoot/../modules/Helpers.psm1" -Force

$groupObjectId = $env:ENTRA_GROUP_OBJECT_ID

if (-not $groupObjectId) {
    Write-Host "ENTRA_GROUP_OBJECT_ID not configured. Skipping sync."
    return
}

Write-Host "Syncing Entra ID group: $groupObjectId ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))"

try {
    # === Get group members from Microsoft Graph ===
    $token = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com').Token
    $membersUri = "https://graph.microsoft.com/v1.0/groups/$groupObjectId/members?`$select=id,displayName,mail,userPrincipalName&`$top=999"

    $members = @()
    $nextLink = $membersUri

    while ($nextLink) {
        $response = Invoke-RestMethod -Uri $nextLink -Method GET `
            -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
        $members += $response.value
        $nextLink = $response.'@odata.nextLink'
    }

    Write-Host "Found $($members.Count) members in group."

    if ($members.Count -eq 0) { return }

    # === Check which users are already provisioned ===
    # We use a simple convention: if rg-{sanitized-upn} exists in any target subscription, the user is provisioned.
    $provisionedUsers = @{}
    $targetSubscriptionIds = ($env:TARGET_SUBSCRIPTION_IDS -split '[,;\s]+') | Where-Object { $_ -ne '' }

    if (-not $targetSubscriptionIds -or $targetSubscriptionIds.Count -eq 0) {
        $targetSubscriptionIds = @((Get-AzContext).Subscription.Id)
    }

    foreach ($member in $members) {
        $upn = $member.userPrincipalName
        if (-not $upn) { continue }

        $sanitized = $upn.ToLower() -replace '@', '-' -replace '\.', '-'
        $rgName = "rg-$sanitized"

        # Check if resource group exists in any target subscription
        foreach ($subId in $targetSubscriptionIds) {
            try {
                Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
                $existing = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
                if ($existing) {
                    $provisionedUsers[$upn] = $true
                    break
                }
            }
            catch {
                # Skip inaccessible subscriptions
            }
        }
    }

    Write-Host "Already provisioned: $($provisionedUsers.Count)"

    # === Start provisioning for new members ===
    $newMembers = $members | Where-Object {
        $_.userPrincipalName -and -not $provisionedUsers.ContainsKey($_.userPrincipalName)
    }

    Write-Host "New members to provision: $($newMembers.Count)"

    foreach ($member in $newMembers) {
        $provisioningInput = @{
            userPrincipalName = $member.userPrincipalName
            displayName       = $member.displayName
            email             = if ($member.mail) { $member.mail } else { $member.userPrincipalName }
            department        = ''
            costCenter        = ''
            subscriptionId    = ''
            location          = $env:DEFAULT_LOCATION
            warningBudget     = [int]$env:DEFAULT_WARNING_BUDGET
            hardLimitBudget   = [int]$env:DEFAULT_HARD_LIMIT_BUDGET
            gracePeriodDays   = [int]$env:DEFAULT_GRACE_PERIOD_DAYS
        }

        Write-Host "Starting provisioning for: $($member.userPrincipalName)"
        $instanceId = Start-DurableOrchestration -FunctionName 'ProvisionOrchestrator' -Input $provisioningInput
        Write-Host "  Orchestration started: $instanceId"
    }

    Write-Host "Sync complete."
}
catch {
    Write-Error "Entra ID group sync failed: $_"
    throw
}
