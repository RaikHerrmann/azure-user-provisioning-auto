<#
.SYNOPSIS
    Remove Microsoft Copilot Studio licenses from users.

.DESCRIPTION
    Reads a user list (same format as the provisioning workflow) and removes
    the Microsoft Copilot Studio license from each user via the Microsoft Graph API.

    This script is independent from the Azure sandbox provisioning functions.

.PARAMETER InputFile
    Path to the CSV or JSON file containing user definitions.
    Must contain a 'UserPrincipalName' column/field.

.PARAMETER SkuPartNumber
    (Optional) Override the auto-detected SKU part number.

.PARAMETER SingleUser
    (Optional) Process only this specific user (by UPN) from the input file.

.PARAMETER WhatIf
    Preview mode — shows which licenses would be removed without removing them.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    # Remove Copilot Studio licenses from all users
    pwsh ./Remove-CopilotStudioLicense.ps1 -InputFile "./users.csv"

.EXAMPLE
    # Remove from a single user
    pwsh ./Remove-CopilotStudioLicense.ps1 -InputFile "./users.csv" -SingleUser "john.doe@contoso.com"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputFile,

    [Parameter(Mandatory = $false)]
    [string]$SkuPartNumber,

    [Parameter(Mandatory = $false)]
    [string]$SingleUser,

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
        return Invoke-RestMethod @params -ErrorAction Stop
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
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║     Microsoft Copilot Studio — License REMOVAL             ║" -ForegroundColor Red
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Red
Write-Host ""

try {
    # ========================================================================
    # Phase 1: Authentication
    # ========================================================================
    Write-Phase "1 - AUTHENTICATION" "Obtaining Microsoft Graph token via Azure CLI"

    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) {
        throw "Not logged in. Run 'az login --tenant YOUR_TENANT_ID' first."
    }
    Write-Success "Logged in as $($account.user.name) (Tenant: $($account.tenantId))"

    Write-StepInfo "Requesting Microsoft Graph access token..."
    $tokenResponse = az account get-access-token --resource "https://graph.microsoft.com" 2>$null | ConvertFrom-Json
    if (-not $tokenResponse -or -not $tokenResponse.accessToken) {
        throw "Failed to obtain Microsoft Graph token."
    }
    $graphToken = $tokenResponse.accessToken
    Write-Success "Graph token acquired"

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
        default { throw "Unsupported file format: $extension. Use .csv or .json." }
    }

    # Filter to single user if specified
    if ($SingleUser) {
        $users = $users | Where-Object { $_.UserPrincipalName -eq $SingleUser }
        if ($users.Count -eq 0) {
            throw "User '$SingleUser' not found in $InputFile."
        }
    }

    if ($users.Count -eq 0) { throw "No users found in $InputFile." }
    Write-Success "Found $($users.Count) user(s) to process"

    # ========================================================================
    # Phase 3: Find Copilot Studio SKU
    # ========================================================================
    Write-Phase "3 - LICENSE DISCOVERY" "Finding Copilot Studio SKU in tenant"

    $skusResponse = Invoke-GraphApi -Uri "https://graph.microsoft.com/v1.0/subscribedSkus" -Token $graphToken
    $allSkus = $skusResponse.value

    $copilotSku = $null
    if ($SkuPartNumber) {
        $copilotSku = $allSkus | Where-Object { $_.skuPartNumber -eq $SkuPartNumber }
        if (-not $copilotSku) { throw "SKU '$SkuPartNumber' not found in tenant." }
    }
    else {
        $candidates = $allSkus | Where-Object {
            ($_.skuPartNumber -match 'copilot.*studio|studio.*copilot') -or
            ($_.skuPartNumber -match 'COPILOT_STUDIO') -or
            ($_.skuPartNumber -match 'Microsoft_Copilot_Studio')
        }
        if ($candidates.Count -eq 0) {
            throw "Could not auto-detect Copilot Studio SKU. Use -SkuPartNumber to specify manually."
        }
        $copilotSku = $candidates[0]
    }

    $skuId = $copilotSku.skuId
    $skuName = $copilotSku.skuPartNumber
    Write-Success "Found: $skuName (SKU ID: $skuId)"

    # ========================================================================
    # Phase 4: Remove Licenses
    # ========================================================================
    Write-Phase "4 - LICENSE REMOVAL" "Removing $skuName from $($users.Count) user(s)"

    if (-not $Force -and -not $WhatIfPreference) {
        Write-Host ""
        $confirm = Read-Host "  Remove '$skuName' from $($users.Count) user(s)? Type 'yes' to confirm"
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

        # Check if user has the license
        Write-StepInfo "Checking current licenses..."
        try {
            $userLicenses = Invoke-GraphApi `
                -Uri "https://graph.microsoft.com/v1.0/users/$($user.UserPrincipalName)/licenseDetails" `
                -Token $graphToken
        }
        catch {
            Write-Warn "Cannot read licenses for $($user.UserPrincipalName): $_"
            $results += [PSCustomObject]@{ User = $user.UserPrincipalName; Status = 'FAILED'; Reason = "Cannot read user: $_" }
            continue
        }

        $hasLicense = $userLicenses.value | Where-Object { $_.skuId -eq $skuId }
        if (-not $hasLicense) {
            Write-StepInfo "Does not have $skuName — skipping."
            $results += [PSCustomObject]@{ User = $user.UserPrincipalName; Status = 'SKIPPED'; Reason = 'License not assigned' }
            continue
        }

        if ($WhatIfPreference) {
            Write-StepInfo "WHAT-IF: Would remove $skuName"
            $results += [PSCustomObject]@{ User = $user.UserPrincipalName; Status = 'WHAT-IF'; Reason = 'Would remove license' }
            continue
        }

        Write-StepInfo "Removing $skuName..."
        $removeBody = @{
            addLicenses    = @()
            removeLicenses = @( $skuId )
        } | ConvertTo-Json -Depth 4

        try {
            Invoke-GraphApi `
                -Method 'POST' `
                -Uri "https://graph.microsoft.com/v1.0/users/$($user.UserPrincipalName)/assignLicense" `
                -Body $removeBody `
                -Token $graphToken | Out-Null

            Write-Success "License removed successfully"
            $results += [PSCustomObject]@{ User = $user.UserPrincipalName; Status = 'SUCCESS'; Reason = "Removed $skuName" }
        }
        catch {
            Write-Warn "Removal FAILED: $_"
            $results += [PSCustomObject]@{ User = $user.UserPrincipalName; Status = 'FAILED'; Reason = "$_" }
        }
    }

    # ========================================================================
    # Phase 5: Summary
    # ========================================================================
    Write-Phase "5 - SUMMARY" "License removal results"

    $results | Format-Table -AutoSize

    $succeeded = ($results | Where-Object { $_.Status -eq 'SUCCESS' }).Count
    $skipped   = ($results | Where-Object { $_.Status -eq 'SKIPPED' }).Count
    $failed    = ($results | Where-Object { $_.Status -eq 'FAILED' }).Count

    Write-Host ""
    Write-Host "  Succeeded: $succeeded | Skipped: $skipped | Failed: $failed | Total: $($results.Count)" -ForegroundColor $(if ($failed -gt 0) { 'Yellow' } else { 'Green' })
}
catch {
    Write-Host ""
    Write-Host "  FATAL ERROR: $_" -ForegroundColor Red
    Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkRed
    throw
}
