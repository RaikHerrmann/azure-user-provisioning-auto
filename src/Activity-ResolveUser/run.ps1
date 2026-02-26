<#
.SYNOPSIS
    Activity: Resolve a user principal name to an Entra ID Object ID.
#>
param($input)

$upn = $input.userPrincipalName
Write-Host "Resolving Entra ID identity for: $upn"

try {
    # Use Microsoft Graph REST API via Managed Identity
    $token = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com').Token
    $uri = "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($upn))?`$select=id,displayName,mail,userPrincipalName"

    $response = Invoke-RestMethod -Uri $uri -Method GET `
        -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
        -ErrorAction Stop

    Write-Host "Resolved: $upn -> $($response.id)"

    return @{
        objectId          = $response.id
        displayName       = $response.displayName
        mail              = $response.mail
        userPrincipalName = $response.userPrincipalName
    }
}
catch {
    Write-Warning "Failed to resolve user '$upn': $_"
    return @{ objectId = $null; error = "$_" }
}
