<#
.SYNOPSIS
    Activity: Deploy the per-user Bicep environment (RG, RBAC, AI Foundry, Budget, Automation).

.DESCRIPTION
    Uses the pre-compiled ARM template (userEnvironment.json) included in the
    function app package. Deploys at subscription scope via New-AzSubscriptionDeployment.
#>
param($input)

$upn = $input.userPrincipalName
$subscriptionId = $input.subscriptionId

Write-Host "Deploying environment for: $upn (sub: $subscriptionId)"

try {
    # Set subscription context
    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop

    # Register required resource providers
    $requiredProviders = @(
        'Microsoft.MachineLearningServices'
        'Microsoft.CognitiveServices'
        'Microsoft.Automation'
        'Microsoft.Consumption'
        'Microsoft.Insights'
        'Microsoft.PolicyInsights'
        'Microsoft.Storage'
        'Microsoft.KeyVault'
        'Microsoft.OperationalInsights'
    )
    foreach ($provider in $requiredProviders) {
        $state = (Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction SilentlyContinue).RegistrationState
        if ($state -ne 'Registered') {
            Write-Host "  Registering provider: $provider"
            Register-AzResourceProvider -ProviderNamespace $provider -ErrorAction SilentlyContinue
        }
    }

    # Resolve the ARM template path
    # The templates are compiled from Bicep at build time and included in the package
    $templatePath = Join-Path $PSScriptRoot '..' 'templates' 'userEnvironment.json'
    if (-not (Test-Path $templatePath)) {
        throw "ARM template not found at: $templatePath. Ensure the CI/CD pipeline compiled the Bicep files."
    }

    # Get the Function App's managed identity principal ID
    $currentContext = Get-AzContext
    $provisioningPrincipalId = (Get-AzADServicePrincipal -ApplicationId $currentContext.Account.Id -ErrorAction SilentlyContinue).Id
    if (-not $provisioningPrincipalId) {
        # Fallback: use the token claims
        $token = Get-AzAccessToken -ResourceUrl 'https://management.azure.com'
        $claims = [System.IdentityModel.Tokens.Jwt.JwtSecurityToken]::new($token.Token)
        $provisioningPrincipalId = $claims.Claims | Where-Object { $_.Type -eq 'oid' } | Select-Object -ExpandProperty Value
    }

    $budgetStartDate = (Get-Date -Day 1).ToString('yyyy-MM-01')
    $deploymentName = "user-env-$($upn -replace '@','-' -replace '\.','-')-$(Get-Date -Format 'yyyyMMddHHmm')".ToLower()

    $params = @{
        userPrincipalName       = $upn
        userDisplayName         = $input.displayName
        userEmail               = $input.email
        userObjectId            = $input.userObjectId
        location                = $input.location
        department              = $input.department
        costCenter              = $input.costCenter
        warningBudgetThreshold  = $input.warningBudget
        hardLimitBudgetThreshold = $input.hardLimitBudget
        gracePeriodDays         = $input.gracePeriodDays
        provisioningPrincipalId = $provisioningPrincipalId
        budgetStartDate         = $budgetStartDate
    }

    Write-Host "Starting subscription-scope deployment: $deploymentName"

    $deployment = New-AzSubscriptionDeployment `
        -Name $deploymentName `
        -Location $input.location `
        -TemplateFile $templatePath `
        -TemplateParameterObject $params `
        -ErrorAction Stop

    if ($deployment.ProvisioningState -eq 'Succeeded') {
        Write-Host "Deployment succeeded for $upn"
        return @{
            status                = 'Succeeded'
            resourceGroupName     = $deployment.Outputs.resourceGroupName.Value
            aiFoundryHubName      = $deployment.Outputs.aiFoundryHubName.Value
            aiFoundryProjectName  = $deployment.Outputs.aiFoundryProjectName.Value
            budgetName            = $deployment.Outputs.budgetName.Value
            automationAccountName = $deployment.Outputs.automationAccountName.Value
        }
    }
    else {
        throw "Deployment state: $($deployment.ProvisioningState)"
    }
}
catch {
    Write-Warning "Deployment failed for '$upn': $_"
    return @{ status = 'Failed'; error = "$_" }
}
