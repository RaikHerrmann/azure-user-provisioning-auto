<#
.SYNOPSIS
    Activity: Create an Azure subscription for a user under the shared billing account.
#>
param($input)

$upn = $input.userPrincipalName
$billingScope = $input.billingScope
$displayName = $input.displayName

Write-Host "Creating subscription for: $upn (billing: $billingScope)"

if (-not $billingScope) {
    Write-Warning "No billing scope configured. Cannot create subscription."
    return @{ subscriptionId = $null; error = 'No billing scope' }
}

try {
    $token = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com').Token

    # Determine billing type from scope path
    $isMCA = $billingScope -match 'invoiceSections'
    $isEA  = $billingScope -match 'enrollmentAccounts'

    $subscriptionAlias = "sub-$($upn -replace '@','-' -replace '\.','-')".ToLower()
    $subscriptionDisplayName = "Sandbox - $displayName"

    if ($isMCA) {
        # MCA subscription creation
        $uri = "https://management.azure.com/providers/Microsoft.Subscription/aliases/${subscriptionAlias}?api-version=2021-10-01"
        $body = @{
            properties = @{
                displayName  = $subscriptionDisplayName
                billingScope = $billingScope
                workload     = 'Production'
            }
        } | ConvertTo-Json -Depth 5
    }
    elseif ($isEA) {
        # EA subscription creation
        $uri = "https://management.azure.com/providers/Microsoft.Subscription/aliases/${subscriptionAlias}?api-version=2021-10-01"
        $body = @{
            properties = @{
                displayName  = $subscriptionDisplayName
                billingScope = $billingScope
                workload     = 'Production'
            }
        } | ConvertTo-Json -Depth 5
    }
    else {
        Write-Warning "Unsupported billing scope format: $billingScope"
        return @{ subscriptionId = $null; error = 'Unsupported billing type' }
    }

    Write-Host "Creating subscription alias: $subscriptionAlias"

    $response = Invoke-RestMethod -Uri $uri -Method PUT -Body $body `
        -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
        -ErrorAction Stop

    # Poll for completion (subscription creation is async)
    $maxWait = 300 # 5 minutes
    $elapsed = 0
    $subscriptionId = $null

    while ($elapsed -lt $maxWait) {
        Start-Sleep -Seconds 15
        $elapsed += 15

        $statusResponse = Invoke-RestMethod -Uri $uri -Method GET `
            -Headers @{ Authorization = "Bearer $token" } -ErrorAction SilentlyContinue

        if ($statusResponse.properties.subscriptionId) {
            $subscriptionId = $statusResponse.properties.subscriptionId
            break
        }

        $provisioningState = $statusResponse.properties.provisioningState
        Write-Host "  Subscription creation state: $provisioningState ($elapsed s)"

        if ($provisioningState -eq 'Failed') {
            throw "Subscription creation failed"
        }
    }

    if ($subscriptionId) {
        Write-Host "Subscription created: $subscriptionId"
        return @{ subscriptionId = $subscriptionId; alias = $subscriptionAlias }
    }
    else {
        throw "Subscription creation timed out after $maxWait seconds"
    }
}
catch {
    Write-Warning "Failed to create subscription for '$upn': $_"
    return @{ subscriptionId = $null; error = "$_" }
}
