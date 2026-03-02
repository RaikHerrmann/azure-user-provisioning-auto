<#
.SYNOPSIS
    Show Copilot Studio license status for the tenant and/or specific users.

.DESCRIPTION
    A diagnostic tool that displays:
    - All license SKUs in the tenant (highlights Copilot-related ones)
    - Per-user license assignment status for users in an input file
    - Available vs consumed license counts

    This script makes NO changes — it is read-only / informational.

.PARAMETER InputFile
    (Optional) Path to the CSV or JSON file containing user definitions.
    If provided, shows per-user license details.

.PARAMETER ShowAllSkus
    Show all SKUs in the tenant, not just Copilot-related ones.

.EXAMPLE
    # Show Copilot Studio SKU status for the tenant
    pwsh ./Get-LicenseStatus.ps1

.EXAMPLE
    # Show per-user license status
    pwsh ./Get-LicenseStatus.ps1 -InputFile "./users.csv"

.EXAMPLE
    # Show ALL tenant SKUs (not just Copilot)
    pwsh ./Get-LicenseStatus.ps1 -ShowAllSkus
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$InputFile,

    [Parameter(Mandatory = $false)]
    [switch]$ShowAllSkus
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Helpers
# ============================================================================
function Write-StepInfo { param([string]$M) Write-Host "  → $M" -ForegroundColor White }
function Write-Success  { param([string]$M) Write-Host "  ✓ $M" -ForegroundColor Green  }
function Write-Warn     { param([string]$M) Write-Host "  ⚠ $M" -ForegroundColor Yellow }

function Invoke-GraphApi {
    param(
        [string]$Uri,
        [string]$Token
    )
    try {
        return Invoke-RestMethod -Uri $Uri -Method GET `
            -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
            -ErrorAction Stop
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        throw "Graph API GET $Uri failed (HTTP $statusCode): $($_.ErrorDetails.Message)"
    }
}

# ============================================================================
# Banner
# ============================================================================
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     Microsoft Copilot Studio — License Status              ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

try {
    # Authenticate
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) {
        throw "Not logged in. Run 'az login --tenant YOUR_TENANT_ID' first."
    }
    Write-Success "Logged in as $($account.user.name) (Tenant: $($account.tenantId))"

    $tokenResponse = az account get-access-token --resource "https://graph.microsoft.com" 2>$null | ConvertFrom-Json
    if (-not $tokenResponse) { throw "Failed to obtain Microsoft Graph token." }
    $graphToken = $tokenResponse.accessToken

    # ========================================================================
    # Tenant SKU Overview
    # ========================================================================
    Write-Host ""
    Write-Host "  ── Tenant License SKUs ──" -ForegroundColor Yellow

    $skusResponse = Invoke-GraphApi -Uri "https://graph.microsoft.com/v1.0/subscribedSkus" -Token $graphToken
    $allSkus = $skusResponse.value

    if ($ShowAllSkus) {
        $displaySkus = $allSkus
        Write-StepInfo "Showing all $($allSkus.Count) SKUs:"
    }
    else {
        $displaySkus = $allSkus | Where-Object { $_.skuPartNumber -match 'copilot|studio' }
        if ($displaySkus.Count -eq 0) {
            Write-Warn "No Copilot-related SKUs found. Use -ShowAllSkus to see all licenses."
            Write-Host ""
            exit 0
        }
        Write-StepInfo "Copilot-related SKUs ($($displaySkus.Count) found):"
    }

    Write-Host ""
    $skuTable = $displaySkus | ForEach-Object {
        [PSCustomObject]@{
            SKU          = $_.skuPartNumber
            'SKU ID'     = $_.skuId
            Total        = $_.prepaidUnits.enabled
            Consumed     = $_.consumedUnits
            Available    = ($_.prepaidUnits.enabled - $_.consumedUnits)
            Status       = $_.capabilityStatus
        }
    }
    $skuTable | Format-Table -AutoSize

    # ========================================================================
    # Per-User License Details (if input file provided)
    # ========================================================================
    if ($InputFile) {
        Write-Host "  ── Per-User License Status ──" -ForegroundColor Yellow

        $resolvedPath = Resolve-Path $InputFile -ErrorAction Stop
        $extension = [System.IO.Path]::GetExtension($resolvedPath).ToLower()

        $users = @()
        switch ($extension) {
            '.csv' {
                $csvData = Import-Csv -Path $resolvedPath
                foreach ($row in $csvData) {
                    if ($row.UserPrincipalName.Trim()) {
                        $users += $row.UserPrincipalName.Trim()
                    }
                }
            }
            '.json' {
                $jsonData = Get-Content -Path $resolvedPath -Raw | ConvertFrom-Json
                $jsonUsers = if ($jsonData.users) { $jsonData.users } else { $jsonData }
                foreach ($u in $jsonUsers) {
                    if ($u.userPrincipalName.Trim()) {
                        $users += $u.userPrincipalName.Trim()
                    }
                }
            }
            default { throw "Unsupported file format: $extension" }
        }

        Write-StepInfo "Checking $($users.Count) user(s)..."
        Write-Host ""

        # Find Copilot Studio SKU IDs for highlighting
        $copilotSkuIds = ($allSkus | Where-Object {
            ($_.skuPartNumber -match 'copilot.*studio|studio.*copilot') -or
            ($_.skuPartNumber -match 'COPILOT_STUDIO') -or
            ($_.skuPartNumber -match 'Microsoft_Copilot_Studio')
        }).skuId

        $userResults = @()
        foreach ($upn in $users) {
            try {
                $userLicenses = Invoke-GraphApi `
                    -Uri "https://graph.microsoft.com/v1.0/users/$upn/licenseDetails" `
                    -Token $graphToken

                $licenseNames = ($userLicenses.value | ForEach-Object { $_.skuPartNumber }) -join ', '
                $hasCopilotStudio = ($userLicenses.value | Where-Object { $_.skuId -in $copilotSkuIds }).Count -gt 0

                $userResults += [PSCustomObject]@{
                    User            = $upn
                    'Copilot Studio' = if ($hasCopilotStudio) { '✓ Yes' } else { '✗ No' }
                    'All Licenses'   = if ($licenseNames) { $licenseNames } else { '(none)' }
                }
            }
            catch {
                $userResults += [PSCustomObject]@{
                    User            = $upn
                    'Copilot Studio' = '? Error'
                    'All Licenses'   = "Error: $_"
                }
            }
        }

        $userResults | Format-Table -AutoSize -Wrap
    }

    Write-Host ""
    Write-Success "License status check complete."
}
catch {
    Write-Host ""
    Write-Host "  FATAL ERROR: $_" -ForegroundColor Red
    Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkRed
    throw
}
