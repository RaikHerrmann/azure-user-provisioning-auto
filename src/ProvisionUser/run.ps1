<#
.SYNOPSIS
    HTTP Trigger — Starts provisioning for a single user.

.DESCRIPTION
    Accepts a POST request with user details and starts the Durable Functions
    orchestrator to provision their sandbox environment.

    Requires a valid X-API-Key header (when WEBHOOK_API_KEY is configured).

    POST /api/provision
    Headers:
        X-API-Key: <your-api-key>
    Body:
    {
        "userPrincipalName": "john.doe@contoso.com",
        "displayName": "John Doe",
        "email": "john.doe@contoso.com",
        "department": "Engineering",
        "costCenter": "CC-1001",
        "subscriptionId": "",           // optional: pin to specific subscription
        "location": "swedencentral",    // optional: override default region
        "warningBudget": 15,            // optional
        "hardLimitBudget": 20,          // optional
        "gracePeriodDays": 5            // optional
    }

    Returns a 202 Accepted with status query URLs for tracking the orchestration.
#>
using namespace System.Net

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../modules/Helpers.psm1" -Force

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

# === Validate Request Body ===
$body = $Request.Body

if (-not $body) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = '{"error": "Request body is required."}'
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# Required fields
$requiredFields = @('userPrincipalName', 'displayName', 'email')
$missing = $requiredFields | Where-Object { -not $body.$_ }
if ($missing) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = (@{ error = "Missing required fields: $($missing -join ', ')" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# === Build Provisioning Input ===
$provisioningInput = @{
    userPrincipalName = $body.userPrincipalName
    displayName       = $body.displayName
    email             = $body.email
    department        = if ($body.department)    { $body.department }    else { '' }
    costCenter        = if ($body.costCenter)    { $body.costCenter }    else { '' }
    subscriptionId    = if ($body.subscriptionId){ $body.subscriptionId } else { '' }
    location          = if ($body.location)      { $body.location }      else { $env:DEFAULT_LOCATION }
    warningBudget     = if ($body.warningBudget) { [int]$body.warningBudget } else { [int]$env:DEFAULT_WARNING_BUDGET }
    hardLimitBudget   = if ($body.hardLimitBudget) { [int]$body.hardLimitBudget } else { [int]$env:DEFAULT_HARD_LIMIT_BUDGET }
    gracePeriodDays   = if ($body.gracePeriodDays) { [int]$body.gracePeriodDays } else { [int]$env:DEFAULT_GRACE_PERIOD_DAYS }
}

Write-Host "Starting provisioning orchestration for $($provisioningInput.userPrincipalName)"

# === Start Durable Orchestrator ===
$instanceId = Start-DurableOrchestration -FunctionName 'ProvisionOrchestrator' -Input $provisioningInput
Write-Host "Started orchestration: $instanceId"

$response = New-DurableRetryOptions -FirstRetryInterval 5 -MaxNumberOfAttempts 3
Push-OutputBinding -Name Response -Value (New-DurableOrchestrationCheckStatusResponse -Request $Request -InstanceId $instanceId)
