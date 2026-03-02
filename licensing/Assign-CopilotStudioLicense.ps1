<#
.SYNOPSIS
    Assign Microsoft Copilot Studio licenses to users from a CSV or JSON input file.

.DESCRIPTION
    Reads a user list and assigns a Microsoft Copilot Studio license to each user
    via the Microsoft Graph API.

    This script is independent from the Azure sandbox provisioning functions and
    can be run at any time — before, after, or without provisioning environments.

    Authentication uses the Azure CLI's Graph token (az account get-access-token),
    so no additional PowerShell modules are required.

    The script:
    1. Authenticates to Microsoft Graph via Azure CLI
    2. Lists all subscribed license SKUs in the tenant
    3. Auto-detects the Copilot Studio SKU (or accepts a manual override)
    4. Checks each user's current licenses
    5. Assigns the Copilot Studio license to users who don't already have it

.PARAMETER InputFile
    Path to the CSV or JSON file containing user definitions.
    Must contain a 'UserPrincipalName' column/field.

.PARAMETER SkuPartNumber
    (Optional) Override the auto-detected SKU part number.
    Use Get-LicenseStatus.ps1 to list available SKUs if auto-detection fails.
    Common values: 'Microsoft_Copilot_Studio', 'COPILOT_STUDIO'.

.PARAMETER WhatIf
    Preview mode — shows which users would receive licenses without assigning them.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    # Assign Copilot Studio licenses to all users in the CSV
    pwsh ./Assign-CopilotStudioLicense.ps1 -InputFile "./users.csv"

.EXAMPLE
    # Preview only (no changes)
    pwsh ./Assign-CopilotStudioLicense.ps1 -InputFile "./users.csv" -WhatIf

.EXAMPLE
    # Override SKU if auto-detection fails
    pwsh ./Assign-CopilotStudioLicense.ps1 -InputFile "./users.csv" -SkuPartNumber "COPILOT_STUDIO"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputFile,

    [Parameter(Mandatory = $false)]
    [string]$SkuPartNumber,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Helpers
# ============================================================================
function Write-Phase   { param([string]$T, [string]$D) Write-Host "`n$('═' * 65)" -ForegroundColor Cyan; Write-Host "  PHASE: $T" -ForegroundColor Cyan; Write-Host "  $D" -ForegroundColor Gray; Write-Host "$('═' * 65)" -ForegroundColor Cyan }
function Write-StepInfo { param([string]$M) Write-Host "  → $M" -ForegroundColor White }
function Write-Success  { param([string]$M) Write-Host "  ✓ $M" -ForegroundColor Green  }
function Write-Warn     { param([string]$M) Write-Host "  ⚠ $M" -ForegroundColor Yellow }

function Invoke-GraphApi {
    param(
        [string]$Method = 'GET',
        [string]$Uri,
        [string]$Body,
        [string]$Token
    )
    $headers = @{
        Authorization  = "Bearer $Token"
        'Content-Type' = 'application/json'
    }
    $params = @{
        Uri     = $Uri
        Method  = $Method
        Headers = $headers
    }
    if ($Body) { $params.Body = $Body }

    try {
        $response = Invoke-RestMethod @params -ErrorAction Stop
        return $response
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorBody = $_.ErrorDetails.Message
        throw "Graph API $Method $Uri failed (HTTP $statusCode): $errorBody"
    }
}

# ============================================================================
# Banner
# ============================================================================
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║     Microsoft Copilot Studio — License Assignment          ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

try {
    # ========================================================================
    # Phase 1: Authentication
    # ========================================================================
    Write-Phase "1 - AUTHENTICATION" "Obtaining Microsoft Graph token via Azure CLI"

    # Verify Azure CLI login
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) {
        throw "Not logged in. Run 'az login --tenant YOUR_TENANT_ID' first."
    }
    Write-Success "Logged in as $($account.user.name) (Tenant: $($account.tenantId))"

    # Get Graph API token
    Write-StepInfo "Requesting Microsoft Graph access token..."
    $tokenResponse = az account get-access-token --resource "https://graph.microsoft.com" 2>$null | ConvertFrom-Json
    if (-not $tokenResponse -or -not $tokenResponse.accessToken) {
        throw "Failed to obtain Microsoft Graph token. Ensure your account has Graph API access."
    }
    $graphToken = $tokenResponse.accessToken
    Write-Success "Graph token acquired (expires: $($tokenResponse.expiresOn))"

    # Verify Graph access
    Write-StepInfo "Verifying Graph API access..."
    $me = Invoke-GraphApi -Uri "https://graph.microsoft.com/v1.0/me" -Token $graphToken
    Write-Success "Graph API accessible (authenticated as: $($me.displayName))"

    # ========================================================================
    # Phase 2: Read Input File
    # ========================================================================
    Write-Phase "2 - INPUT PARSING" "Reading user list from $InputFile"

    $resolvedPath = Resolve-Path $InputFile -ErrorAction Stop
    $extension = [System.IO.Path]::GetExtension($resolvedPath).ToLower()

    $users = @()
    switch ($extension) {
        '.csv' {
            $csvData = Import-Csv -Path $resolvedPath
            if (-not ($csvData | Get-Member -Name 'UserPrincipalName' -ErrorAction SilentlyContinue)) {
                throw "CSV file missing required 'UserPrincipalName' column."
            }
            foreach ($row in $csvData) {
                if ($row.UserPrincipalName.Trim()) {
                    $users += [PSCustomObject]@{
                        UserPrincipalName = $row.UserPrincipalName.Trim()
                        DisplayName       = if ($row.DisplayName) { $row.DisplayName.Trim() } else { $row.UserPrincipalName.Trim() }
                    }
                }
            }
        }
        '.json' {
            $jsonData = Get-Content -Path $resolvedPath -Raw | ConvertFrom-Json
            $jsonUsers = if ($jsonData.users) { $jsonData.users } else { $jsonData }
            foreach ($u in $jsonUsers) {
                if ($u.userPrincipalName.Trim()) {
                    $users += [PSCustomObject]@{
                        UserPrincipalName = $u.userPrincipalName.Trim()
                        DisplayName       = if ($u.displayName) { $u.displayName.Trim() } else { $u.userPrincipalName.Trim() }
                    }
                }
            }
        }
        default {
            throw "Unsupported file format: $extension. Use .csv or .json."
        }
    }

    if ($users.Count -eq 0) {
        throw "No users found in $InputFile."
    }
    Write-Success "Found $($users.Count) user(s):"
    foreach ($u in $users) {
        Write-StepInfo "  $($u.UserPrincipalName) ($($u.DisplayName))"
    }

    # ========================================================================
    # Phase 3: Discover Copilot Studio License SKU
    # ========================================================================
    Write-Phase "3 - LICENSE DISCOVERY" "Finding Copilot Studio SKU in tenant"

    Write-StepInfo "Listing subscribed license SKUs..."
    $skusResponse = Invoke-GraphApi -Uri "https://graph.microsoft.com/v1.0/subscribedSkus" -Token $graphToken
    $allSkus = $skusResponse.value

    if (-not $allSkus -or $allSkus.Count -eq 0) {
        throw "No license SKUs found in this tenant. Ensure licenses have been purchased."
    }

    Write-StepInfo "Total SKUs in tenant: $($allSkus.Count)"

    # Find the Copilot Studio SKU
    $copilotSku = $null
    if ($SkuPartNumber) {
        # Manual override
        $copilotSku = $allSkus | Where-Object { $_.skuPartNumber -eq $SkuPartNumber }
        if (-not $copilotSku) {
            Write-Warn "SKU '$SkuPartNumber' not found in tenant. Available SKUs:"
            $allSkus | ForEach-Object {
                Write-StepInfo "  $($_.skuPartNumber) — $($_.skuId) (consumed: $($_.consumedUnits)/$($_.prepaidUnits.enabled))"
            }
            throw "Specified SKU part number '$SkuPartNumber' does not exist in this tenant."
        }
    }
    else {
        # Auto-detect: search for SKUs with "copilot" AND "studio" in the part number or display name
        $candidates = $allSkus | Where-Object {
            ($_.skuPartNumber -match 'copilot.*studio|studio.*copilot') -or
            ($_.skuPartNumber -match 'COPILOT_STUDIO') -or
            ($_.skuPartNumber -match 'Microsoft_Copilot_Studio')
        }

        if ($candidates.Count -eq 0) {
            # Broader search: anything with "copilot" in it
            $broadCandidates = $allSkus | Where-Object { $_.skuPartNumber -match 'copilot' }
            if ($broadCandidates.Count -gt 0) {
                Write-Warn "No exact 'Copilot Studio' SKU found, but these Copilot-related SKUs exist:"
                $broadCandidates | ForEach-Object {
                    Write-StepInfo "  $($_.skuPartNumber) — consumed: $($_.consumedUnits)/$($_.prepaidUnits.enabled)"
                }
                Write-Host ""
                Write-Warn "Re-run with -SkuPartNumber to specify the correct SKU."
            }
            else {
                Write-Warn "No Copilot-related SKUs found. All available SKUs:"
                $allSkus | ForEach-Object {
                    Write-StepInfo "  $($_.skuPartNumber) — consumed: $($_.consumedUnits)/$($_.prepaidUnits.enabled)"
                }
            }
            throw "Could not auto-detect a Copilot Studio license SKU. Purchase the license in the Microsoft 365 Admin Center, or use -SkuPartNumber to specify manually."
        }
        elseif ($candidates.Count -gt 1) {
            Write-Warn "Multiple Copilot Studio SKUs found:"
            $candidates | ForEach-Object {
                Write-StepInfo "  $($_.skuPartNumber) — consumed: $($_.consumedUnits)/$($_.prepaidUnits.enabled)"
            }
            Write-Warn "Using the first match. To override, use -SkuPartNumber."
            $copilotSku = $candidates[0]
        }
        else {
            $copilotSku = $candidates[0]
        }
    }

    $skuId = $copilotSku.skuId
    $skuName = $copilotSku.skuPartNumber
    $totalLicenses = $copilotSku.prepaidUnits.enabled
    $consumedLicenses = $copilotSku.consumedUnits
    $availableLicenses = $totalLicenses - $consumedLicenses

    Write-Success "Found: $skuName"
    Write-StepInfo "  SKU ID:    $skuId"
    Write-StepInfo "  Total:     $totalLicenses"
    Write-StepInfo "  Consumed:  $consumedLicenses"
    Write-StepInfo "  Available: $availableLicenses"

    if ($availableLicenses -le 0) {
        throw "No available Copilot Studio licenses. All $totalLicenses licenses are consumed. Purchase more in the Microsoft 365 Admin Center."
    }

    if ($availableLicenses -lt $users.Count) {
        Write-Warn "Only $availableLicenses licenses available but $($users.Count) users to process. Some assignments will fail."
    }

    # ========================================================================
    # Phase 4: Assign Licenses
    # ========================================================================
    Write-Phase "4 - LICENSE ASSIGNMENT" "Assigning $skuName to $($users.Count) user(s)"

    if (-not $Force -and -not $WhatIfPreference) {
        Write-Host ""
        $confirm = Read-Host "  Assign '$skuName' to $($users.Count) user(s)? Type 'yes' to confirm"
        if ($confirm -ne 'yes') {
            Write-Host "  Cancelled." -ForegroundColor Yellow
            exit 0
        }
    }

    $results = @()
    $userIndex = 0

    foreach ($user in $users) {
        $userIndex++
        Write-Host ""
        Write-Host "  ── User $userIndex/$($users.Count): $($user.DisplayName) ──" -ForegroundColor Yellow

        # Check if user already has the license
        Write-StepInfo "Checking current licenses..."
        try {
            $userLicenses = Invoke-GraphApi `
                -Uri "https://graph.microsoft.com/v1.0/users/$($user.UserPrincipalName)/licenseDetails" `
                -Token $graphToken
        }
        catch {
            Write-Warn "Cannot read licenses for $($user.UserPrincipalName): $_"
            $results += [PSCustomObject]@{
                User = $user.UserPrincipalName; Status = 'FAILED'; Reason = "Cannot read user: $_"
            }
            continue
        }

        $alreadyAssigned = $userLicenses.value | Where-Object { $_.skuId -eq $skuId }
        if ($alreadyAssigned) {
            Write-Success "Already has $skuName — skipping."
            $results += [PSCustomObject]@{
                User = $user.UserPrincipalName; Status = 'SKIPPED'; Reason = 'Already assigned'
            }
            continue
        }

        if ($WhatIfPreference) {
            Write-StepInfo "WHAT-IF: Would assign $skuName"
            $results += [PSCustomObject]@{
                User = $user.UserPrincipalName; Status = 'WHAT-IF'; Reason = 'Would assign license'
            }
            continue
        }

        # Assign the license
        Write-StepInfo "Assigning $skuName..."
        $assignBody = @{
            addLicenses    = @(
                @{ skuId = $skuId }
            )
            removeLicenses = @()
        } | ConvertTo-Json -Depth 4

        try {
            Invoke-GraphApi `
                -Method 'POST' `
                -Uri "https://graph.microsoft.com/v1.0/users/$($user.UserPrincipalName)/assignLicense" `
                -Body $assignBody `
                -Token $graphToken | Out-Null

            Write-Success "License assigned successfully"
            $results += [PSCustomObject]@{
                User = $user.UserPrincipalName; Status = 'SUCCESS'; Reason = "Assigned $skuName"
            }
        }
        catch {
            Write-Warn "Assignment FAILED: $_"
            $results += [PSCustomObject]@{
                User = $user.UserPrincipalName; Status = 'FAILED'; Reason = "$_"
            }
        }
    }

    # ========================================================================
    # Phase 5: Summary
    # ========================================================================
    Write-Phase "5 - SUMMARY" "License assignment results"

    $results | Format-Table -AutoSize

    $succeeded = ($results | Where-Object { $_.Status -eq 'SUCCESS' }).Count
    $skipped   = ($results | Where-Object { $_.Status -eq 'SKIPPED' }).Count
    $failed    = ($results | Where-Object { $_.Status -eq 'FAILED' }).Count
    $whatif    = ($results | Where-Object { $_.Status -eq 'WHAT-IF' }).Count

    Write-Host ""
    Write-Host "  Succeeded: $succeeded | Skipped: $skipped | Failed: $failed | What-If: $whatif | Total: $($results.Count)" -ForegroundColor $(if ($failed -gt 0) { 'Yellow' } else { 'Green' })

    # Save results
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent $scriptDir
    $outputDir = Join-Path $repoRoot 'output'
    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
    $resultFile = Join-Path $outputDir "license-results-$timestamp.csv"
    $results | Export-Csv -Path $resultFile -NoTypeInformation
    Write-Success "Results saved to $resultFile"
}
catch {
    Write-Host ""
    Write-Host "  FATAL ERROR: $_" -ForegroundColor Red
    Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkRed
    throw
}
