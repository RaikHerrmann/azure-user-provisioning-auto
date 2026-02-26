<#
.SYNOPSIS
    Activity: Upload runbook scripts and wire webhook to the Automation Account.

.DESCRIPTION
    After the Bicep deployment creates the Automation Account shell,
    this activity uploads the actual PowerShell runbook content and
    wires the budget action group webhook for real-time enforcement.
#>
param($input)

$subscriptionId = $input.subscriptionId
$rgName = $input.resourceGroupName
$aaName = $input.automationAccountName
$budgetName = $input.budgetName

Write-Host "Configuring runbooks for: $rgName / $aaName"

try {
    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
    $token = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com').Token

    # === Upload Runbook Content ===
    $runbooksPath = Join-Path $PSScriptRoot '..' 'runbooks'
    $runbooks = @(
        @{ Name = 'Invoke-CostEnforcement';    File = Join-Path $runbooksPath 'Invoke-CostEnforcement.ps1' }
        @{ Name = 'Invoke-GracePeriodCleanup'; File = Join-Path $runbooksPath 'Invoke-GracePeriodCleanup.ps1' }
    )

    foreach ($rb in $runbooks) {
        if (-not (Test-Path $rb.File)) {
            Write-Warning "Runbook file not found: $($rb.File)"
            continue
        }

        Write-Host "  Uploading $($rb.Name)..."
        $runbookContent = Get-Content -Path $rb.File -Raw

        $putUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Automation/automationAccounts/$aaName/runbooks/$($rb.Name)/draft/content?api-version=2023-11-01"
        Invoke-RestMethod -Uri $putUri -Method PUT -Body $runbookContent `
            -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'text/powershell' } `
            -ErrorAction Stop
        Write-Host "  Uploaded $($rb.Name)"

        # Publish the runbook
        Write-Host "  Publishing $($rb.Name)..."
        $publishUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Automation/automationAccounts/$aaName/runbooks/$($rb.Name)/publish?api-version=2023-11-01"
        Invoke-RestMethod -Uri $publishUri -Method POST `
            -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
            -ErrorAction Stop
        Write-Host "  Published $($rb.Name)"
    }

    # === Wire Webhook for Budget Enforcement ===
    Write-Host "  Wiring webhook for budget enforcement..."
    try {
        $webhookName = "cost-enforce-wh"
        $expiryDate = (Get-Date).AddYears(1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.0000000+00:00')

        $webhookUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Automation/automationAccounts/$aaName/webhooks/${webhookName}?api-version=2023-11-01"
        $webhookBody = @{
            name       = $webhookName
            properties = @{
                isEnabled  = $true
                expiryTime = $expiryDate
                runbook    = @{ name = 'Invoke-CostEnforcement' }
            }
        } | ConvertTo-Json -Depth 4

        $webhookResult = Invoke-RestMethod -Uri $webhookUri -Method PUT -Body $webhookBody `
            -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
            -ErrorAction Stop

        if ($webhookResult.properties.uri) {
            $webhookCallbackUri = $webhookResult.properties.uri
            Write-Host "  Webhook created"

            # Get budget unique suffix from budget name
            $uniqueSuffix = $budgetName -replace 'budget-', ''
            $agName = "ag-enforce-$uniqueSuffix"
            $automationAccountId = "/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Automation/automationAccounts/$aaName"
            $webhookResourceId = "$automationAccountId/webhooks/$webhookName"

            # Update action group with automation runbook receiver
            $agUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Insights/actionGroups/${agName}?api-version=2023-09-01-preview"
            $agCurrent = Invoke-RestMethod -Uri $agUri -Method GET `
                -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop

            $agCurrent.properties | Add-Member -NotePropertyName 'automationRunbookReceivers' -NotePropertyValue @(
                @{
                    name                = 'CostEnforce'
                    automationAccountId = $automationAccountId
                    runbookName         = 'Invoke-CostEnforcement'
                    webhookResourceId   = $webhookResourceId
                    isGlobalRunbook     = $false
                    serviceUri          = $webhookCallbackUri
                    useCommonAlertSchema = $true
                }
            ) -Force

            $agBody = $agCurrent | ConvertTo-Json -Depth 10
            Invoke-RestMethod -Uri $agUri -Method PUT -Body $agBody `
                -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
                -ErrorAction Stop

            Write-Host "  Action group wired to webhook"
        }
    }
    catch {
        Write-Warning "  Webhook wiring failed (daily schedule is backup): $_"
    }

    return @{ status = 'Configured' }
}
catch {
    Write-Warning "Runbook configuration failed: $_"
    return @{ status = 'PartiallyConfigured'; error = "$_" }
}
