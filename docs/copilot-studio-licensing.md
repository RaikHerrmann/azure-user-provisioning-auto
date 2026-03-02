# Copilot Studio Licensing

This guide explains how to assign and manage **Microsoft Copilot Studio** licenses for users, using the scripts in the `licensing/` folder.

> **Independent from sandbox provisioning.** These scripts can be run at any time — before, after, or completely independently of the event-driven provisioning workflow. They accept the same CSV/JSON user format for convenience.

---

## Overview

| Script | Purpose | Makes Changes? |
|--------|---------|----------------|
| `Get-LicenseStatus.ps1` | Show tenant SKUs and per-user license status | No (read-only) |
| `Assign-CopilotStudioLicense.ps1` | Assign Copilot Studio license to users | Yes |
| `Remove-CopilotStudioLicense.ps1` | Remove Copilot Studio license from users | Yes |

All scripts use the **Microsoft Graph API** via Azure CLI tokens — no additional PowerShell modules required.

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **Azure CLI** | ≥ 2.60 ([install](https://aka.ms/installazurecli)) |
| **PowerShell** | ≥ 7.4 |
| **Azure CLI login** | `az login --tenant YOUR_TENANT_ID` |
| **Copilot Studio licenses** | Must be purchased in the [Microsoft 365 Admin Center](https://admin.microsoft.com) |
| **Admin permissions** | One of: **Global Administrator**, **License Administrator**, or **User Administrator** |

### Required Microsoft Graph Permissions

When using an interactive login (`az login`), the admin's delegated permissions are used automatically. For service principal / CI/CD automation, the app registration needs:

| Permission | Type | Why |
|-----------|------|-----|
| `User.ReadWrite.All` | Application | Read user profiles and assign licenses |
| `Directory.Read.All` | Application | List subscribed license SKUs |

---

## Quick Start

```bash
# 1. Log in as tenant admin
az login --tenant YOUR_TENANT_ID

# 2. Check what Copilot Studio licenses exist in your tenant
cd licensing
pwsh ./Get-LicenseStatus.ps1

# 3. Check per-user license status (provide a CSV/JSON user list)
pwsh ./Get-LicenseStatus.ps1 -InputFile "./users.csv"

# 4. Preview license assignment (no changes)
pwsh ./Assign-CopilotStudioLicense.ps1 -InputFile "./users.csv" -WhatIf

# 5. Assign licenses
pwsh ./Assign-CopilotStudioLicense.ps1 -InputFile "./users.csv"
```

### Input File Format

The scripts accept CSV or JSON files with a `UserPrincipalName` field:

**CSV:**
```csv
UserPrincipalName,DisplayName
alice@contoso.com,Alice
bob@contoso.com,Bob
```

**JSON:**
```json
{
  "users": [
    { "userPrincipalName": "alice@contoso.com", "displayName": "Alice" },
    { "userPrincipalName": "bob@contoso.com", "displayName": "Bob" }
  ]
}
```

---

## How It Works

### 1. Authentication

The scripts obtain a Microsoft Graph API access token via:

```
az account get-access-token --resource "https://graph.microsoft.com"
```

This reuses your existing Azure CLI session — the same `az login` you use for managing the platform infrastructure.

### 2. SKU Auto-Detection

The assignment script automatically finds the Copilot Studio license SKU by:

1. Listing all subscribed SKUs via `GET /subscribedSkus`
2. Searching for SKU part numbers matching `Copilot Studio` patterns:
   - `Microsoft_Copilot_Studio`
   - `COPILOT_STUDIO`
   - Any SKU containing both "copilot" and "studio"
3. If auto-detection fails, you can specify the exact SKU with `-SkuPartNumber`

> **Tip:** Run `Get-LicenseStatus.ps1 -ShowAllSkus` to see every license in your tenant and find the exact part number.

### 3. Idempotent Assignment

- Users who **already have** the Copilot Studio license are skipped (no duplicate assignments)
- Users who **don't exist** in Entra ID produce a warning and are skipped
- The script checks available license count before starting and warns if insufficient

### 4. Graph API Calls

| Operation | API Endpoint | Method |
|-----------|-------------|--------|
| List tenant SKUs | `/v1.0/subscribedSkus` | GET |
| Get user licenses | `/v1.0/users/{upn}/licenseDetails` | GET |
| Assign license | `/v1.0/users/{upn}/assignLicense` | POST |
| Remove license | `/v1.0/users/{upn}/assignLicense` | POST |

---

## Script Reference

### Assign-CopilotStudioLicense.ps1

Assigns the Copilot Studio license to all users in the input file.

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-InputFile` | Yes | — | Path to CSV or JSON user file |
| `-SkuPartNumber` | No | (auto-detect) | Override the license SKU part number |
| `-WhatIf` | No | — | Preview mode (no changes) |
| `-Force` | No | — | Skip confirmation prompt |

**Phases:**

| Phase | What It Does |
|-------|-------------|
| 1. Authentication | Gets Graph API token via Azure CLI |
| 2. Input Parsing | Reads users from CSV/JSON |
| 3. License Discovery | Finds Copilot Studio SKU, checks availability |
| 4. License Assignment | Assigns license per user (skips existing) |
| 5. Summary | Shows results table, saves CSV to `output/` |

### Remove-CopilotStudioLicense.ps1

Removes the Copilot Studio license from users.

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-InputFile` | Yes | — | Path to CSV or JSON user file |
| `-SkuPartNumber` | No | (auto-detect) | Override the license SKU part number |
| `-SingleUser` | No | — | Process only this user (by UPN) |
| `-WhatIf` | No | — | Preview mode (no changes) |
| `-Force` | No | — | Skip confirmation prompt |

### Get-LicenseStatus.ps1

Read-only diagnostic tool.

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-InputFile` | No | — | If provided, shows per-user license details |
| `-ShowAllSkus` | No | — | Show all tenant SKUs, not just Copilot-related |

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "No Copilot-related SKUs found" | Purchase Copilot Studio licenses in the [M365 Admin Center](https://admin.microsoft.com > Billing > Purchase services) |
| "Could not auto-detect SKU" | Run `Get-LicenseStatus.ps1 -ShowAllSkus` to find the exact part number, then use `-SkuPartNumber` |
| "Failed to obtain Microsoft Graph token" | Ensure you're logged in with `az login --tenant YOUR_TENANT_ID` and the account has Graph API access |
| "Authorization_RequestDenied" | Your account needs Global Admin, License Admin, or User Admin role |
| "No available licenses" | All purchased licenses are assigned. Purchase more in the M365 Admin Center |
| "User not found" | The user must exist in Entra ID. Ensure the user is provisioned first |

---

## Using with the Event-Driven Provisioning Workflow

While these scripts are fully independent, a typical workflow is:

**Option A — After API-based provisioning:**
```bash
# 1. Provision a user via the HTTP API
curl -X POST "https://<func-app>.azurewebsites.net/api/provision?code=<key>" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <api-key>" \
  -d '{"userPrincipalName": "john.doe@contoso.com", "displayName": "John Doe"}'

# 2. Assign Copilot Studio license
cd licensing
pwsh ./Assign-CopilotStudioLicense.ps1 -InputFile "./users.csv"
```

**Option B — After Entra ID group-based provisioning:**
```bash
# 1. Add user to the Entra ID security group (provisioning happens automatically)
az ad group member add --group "AI Sandbox Users" --member-id "<user-object-id>"

# 2. Assign Copilot Studio license to all group members
cd licensing
pwsh ./Assign-CopilotStudioLicense.ps1 -InputFile "./users.csv"
```

Both provisioning methods create the sandbox environment. The licensing step uses its own input file and can be run at any point independently.

---

## Purchasing Copilot Studio Licenses

If your tenant doesn't have Copilot Studio licenses yet:

1. Go to the [Microsoft 365 Admin Center](https://admin.microsoft.com)
2. Navigate to **Billing** > **Purchase services**
3. Search for **"Copilot Studio"**
4. Select the appropriate plan:
   - **Microsoft Copilot Studio** — per-user license for building and using copilots
   - **Microsoft Copilot Studio viral trial** — free trial (limited)
5. Complete the purchase
6. Wait a few minutes for the SKU to appear in your tenant
7. Run `Get-LicenseStatus.ps1` to verify

> **Note:** Copilot Studio also has **capacity-based** licensing (messages/month) that is tenant-wide and does not require per-user assignment. The scripts in this folder handle the **per-user** license only.
