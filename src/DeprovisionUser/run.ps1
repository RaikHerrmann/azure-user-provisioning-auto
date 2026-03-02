<#
.SYNOPSIS
    HTTP Trigger — Deprovision (tear down) a user's sandbox environment.

.DESCRIPTION
    POST /api/deprovision
    Headers:
        X-API-Key: <your-api-key>
    Body:
    {
        "userPrincipalName": "john.doe@contoso.com",
        "subscriptionId": "xxxx-xxxx"  // optional — auto-detected if omitted
    }

    Removes the resource group, RBAC assignments, and policy for the user.
    If subscriptionId is not provided, the function searches all configured
    target subscriptions (TARGET_SUBSCRIPTION_IDS) for the user's RG.
#>
using namespace System.Net

param($Request, $TriggerMetadata)

# === Validate API Key ===
$expectedKey = $env:WEBHOOK_API_KEY
if ($expectedKey) {
    $providedKey = $Request.Headers['X-API-Key']
    if ($providedKey -ne $expectedKey) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::Unauthorized
            Body       = '{"error": "Invalid or missing API key. Provide a valid X-API-Key header."}'
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }
}

$body = $Request.Body

if (-not $body -or -not $body.userPrincipalName) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = '{"error": "userPrincipalName is required."}'
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

$upn = $body.userPrincipalName
$subscriptionId = $body.subscriptionId

Write-Host "Deprovisioning user: $upn"

$sanitized = $upn.ToLower() -replace '@', '-' -replace '\.', '-'
$rgName = "rg-$sanitized"

try {
    # === Locate the user's resource group ===
    if ($subscriptionId) {
        # Caller specified the subscription
        Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
    }
    else {
        # Search configured target subscriptions for the user's RG
        Write-Host "No subscriptionId provided. Searching target subscriptions for RG: $rgName"
        $targetSubscriptionIds = ($env:TARGET_SUBSCRIPTION_IDS -split '[,;\s]+') | Where-Object { $_ -ne '' }

        if (-not $targetSubscriptionIds -or $targetSubscriptionIds.Count -eq 0) {
            # Fallback: use current context
            $targetSubscriptionIds = @((Get-AzContext).Subscription.Id)
        }

        $found = $false
        foreach ($subId in $targetSubscriptionIds) {
            try {
                Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
                $rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
                if ($rg) {
                    $subscriptionId = $subId
                    $found = $true
                    Write-Host "Found RG '$rgName' in subscription: $subId"
                    break
                }
            }
            catch {
                Write-Warning "Cannot access subscription $subId — skipping."
            }
        }

        if (-not $found) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::NotFound
                Body       = (@{ error = "Resource group '$rgName' not found in any configured subscription." } | ConvertTo-Json)
                Headers    = @{ 'Content-Type' = 'application/json' }
            })
            return
        }
    }

    # Check if resource group exists
    $rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
    if (-not $rg) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body       = (@{ error = "Resource group '$rgName' not found." } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    # Remove the resource group (and all resources within it)
    Write-Host "Deleting resource group: $rgName"
    Remove-AzResourceGroup -Name $rgName -Force -ErrorAction Stop

    # Remove subscription-level policy assignments
    $uniqueSuffix = [System.Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes("$subscriptionId$upn")
    ).Substring(0, 13) -replace '[^a-zA-Z0-9]', ''

    # Try to clean up policy assignment (best-effort)
    try {
        $policyAssignments = Get-AzPolicyAssignment -ErrorAction SilentlyContinue |
            Where-Object { $_.Properties.DisplayName -like "*$rgName*" }
        foreach ($pa in $policyAssignments) {
            Remove-AzPolicyAssignment -Name $pa.Name -ErrorAction SilentlyContinue
        }
        $policyDefinitions = Get-AzPolicyDefinition -Custom -ErrorAction SilentlyContinue |
            Where-Object { $_.Properties.DisplayName -like "*$rgName*" }
        foreach ($pd in $policyDefinitions) {
            Remove-AzPolicyDefinition -Name $pd.Name -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Warning "Policy cleanup partial: $_"
    }

    # Try to clean up custom role (best-effort, only if no other users)
    # Don't remove the Sandbox Contributor role - it's shared per subscription

    Write-Host "Deprovisioning complete for $upn"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = (@{
            status            = 'Deprovisioned'
            user              = $upn
            resourceGroup     = $rgName
        } | ConvertTo-Json)
        Headers = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "Deprovisioning failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ error = "Deprovisioning failed: $_" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
