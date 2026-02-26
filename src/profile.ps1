# Azure Functions profile.ps1
# Executed once when a function app instance starts.

# Authenticate with Azure using the Function App's Managed Identity
if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -ErrorAction Stop
    Write-Host "Authenticated with Managed Identity."
}
