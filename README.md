# Azure User Sandbox Provisioning — Event-Driven

Automated, event-driven provisioning of **per-user Azure sandbox environments** with AI Foundry, cost controls, and zero manual intervention.

> **Evolved from** the [batch CSV-based solution](https://github.com/RaikHerrmann/azure-user-provisioning). Instead of admin-driven batch scripts, this version runs entirely in Azure and provisions users on demand via triggers.

---

## How It Works

An **Azure Function App** (PowerShell + Durable Functions) runs in Azure and reacts to events:

| Trigger | How It Works | Admin Action |
|---------|-------------|--------------|
| **HTTP Webhook** | External system POSTs user details → provisioning starts | None (automated) |
| **Entra ID Group Sync** | Timer checks security group every 10 min → new members auto-provisioned | Add user to group |
| **Deprovision API** | POST to remove endpoint → environment torn down | None (automated) |

Each provisioned user receives the **same isolated sandbox** as the batch solution:

- Dedicated resource group within a shared subscription (scales by adding more subscriptions)
- Azure AI Foundry (Hub + Project) with storage, Key Vault, monitoring
- Tamper-proof cost controls ($15 warning, $20 hard enforcement)
- Automatic enforcement: read-only → resource stop → 5-day grace → deletion

---

## Architecture

```
  Trigger                     Azure Function App                Per-User Environment
  ───────                     ──────────────────                ────────────────────
                              ┌──────────────────────────┐
  POST /api/provision ──────▶ │  Durable Orchestrator     │     ┌──────────────────┐
  + X-API-Key header          │                          │ ──▶ │ Subscription(s)   │
  Entra ID Group Sync ──────▶ │  1. Resolve User          │     │ ├── rg-user-a     │
  (timer, every 10 min)       │  2. Select Subscription   │     │ ├── rg-user-b     │
                              │  3. Deploy Bicep (IaC)    │     │ ├── rg-user-c     │
  POST /api/deprovision ────▶ │  4. Configure Runbooks    │     │ └── ... (up to 950)│
  + X-API-Key header          │                          │     └──────────────────┘
                              └──────────────────────────┘
```

See the full [Architecture](docs/architecture.md) document for detailed diagrams.

---

## Quick Start

### 1. Deploy the Platform (one-time)

The CI/CD pipeline deploys everything automatically on push to `main`. Set up these GitHub repository secrets first:

| Secret | Value |
|--------|-------|
| `AZURE_CLIENT_ID` | Service principal App ID |
| `AZURE_TENANT_ID` | Entra ID tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Platform subscription ID |

Then push to `main` or trigger the workflow manually.

See the [Setup Guide](docs/setup-guide.md) for detailed steps.

### 2. Provision Users

**Option A — API call** (from any system):
```bash
curl -X POST "https://<func-app>.azurewebsites.net/api/provision?code=<function-key>" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <your-api-key>" \
  -d '{
    "userPrincipalName": "john.doe@contoso.com",
    "displayName": "John Doe",
    "email": "john.doe@contoso.com"
  }'
```

**Option B — Entra ID group** (fully automatic):
```bash
# Just add the user to the security group
az ad group member add --group "AI Sandbox Users" --member-id "<user-object-id>"
# Environment provisioned automatically within 10 minutes
```

### 3. Deprovision Users

```bash
curl -X POST "https://<func-app>.azurewebsites.net/api/deprovision?code=<function-key>" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <your-api-key>" \
  -d '{"userPrincipalName": "john.doe@contoso.com"}'
```

> **Note:** `subscriptionId` is optional in the deprovision call — the function auto-detects which subscription holds the user's RG.

---

## What Changed from the Batch Solution

| Aspect | Before (Batch) | Now (Event-Driven) |
|--------|---------------|-------------------|
| Admin workflow | Edit CSV → run script locally | Add user to Entra ID group (or integrate with HR system) |
| Where it runs | Admin's machine / GitHub Actions runner | Azure Function App (always running in Azure) |
| Trigger | Manual script execution | HTTP webhook / timer / Entra ID group change |
| Granularity | Batch (all users at once) | Single user (on demand) |
| Scaling model | One subscription per user | Resource groups within shared subscriptions |
| Long-running ops | Sequential PowerShell | Durable Functions (retry, status tracking) |
| Per-user infra | Bicep modules | Same Bicep modules (unchanged) |
| Webhook auth | N/A | Function key + custom API key (X-API-Key header) |

---

## Project Structure

```
azure-user-provisioning-auto/
├── infra/                                   # Bicep IaC templates
│   ├── main.bicep                           # Platform: Function App, Storage, MI
│   └── modules/
│       ├── functionApp.bicep                # Function App + dependencies
│       ├── userEnvironment.bicep            # Per-user orchestrator (sub scope)
│       ├── rbac.bicep                       # Sandbox Contributor + Admin roles
│       ├── policy.bicep                     # Custom role + naming policy
│       ├── aiFoundry.bicep                  # AI Hub + Project + dependencies
│       ├── budget.bicep                     # Budgets + Action Groups
│       └── costEnforcement.bicep            # Automation Account + runbooks
├── src/                                     # Azure Function App code
│   ├── ProvisionUser/                       # HTTP trigger → start orchestration
│   ├── ProvisionOrchestrator/               # Durable orchestrator
│   ├── Activity-ResolveUser/                # Activity: Entra ID lookup
│   ├── Activity-SelectSubscription/         # Activity: pick sub with RG capacity
│   ├── Activity-DeployEnvironment/          # Activity: Bicep deployment
│   ├── Activity-ConfigureRunbooks/          # Activity: runbook upload + webhook
│   ├── SyncEntraGroup/                      # Timer trigger: group sync
│   ├── DeprovisionUser/                     # HTTP trigger: teardown
│   ├── modules/Helpers.psm1                 # Shared utilities
│   ├── runbooks/                            # Cost enforcement runbooks
│   │   ├── Invoke-CostEnforcement.ps1
│   │   └── Invoke-GracePeriodCleanup.ps1
│   ├── host.json                            # Function App configuration
│   ├── profile.ps1                          # PowerShell startup
│   └── requirements.psd1                    # Az module dependencies
├── licensing/                                # Copilot Studio license management
│   ├── Assign-CopilotStudioLicense.ps1      # Assign licenses to users
│   ├── Remove-CopilotStudioLicense.ps1      # Remove licenses from users
│   └── Get-LicenseStatus.ps1                # Diagnostic: tenant & user status
├── .github/workflows/
│   └── deploy.yml                           # CI/CD: deploy platform + functions
├── docs/
│   ├── architecture.md                      # Detailed architecture
│   ├── copilot-studio-licensing.md          # Copilot Studio licensing guide
│   └── setup-guide.md                       # Step-by-step setup
├── .gitignore
├── LICENSE
└── README.md
```

---

## Security Model

Identical to the batch solution — three layers of protection:

| # | Layer | Mechanism |
|---|-------|-----------|
| 1 | **Custom RBAC Role** | Sandbox Contributor (blocks cost infra modification) |
| 2 | **RBAC Scope** | Role assigned at Resource Group only |
| 3 | **Azure Policy** | Naming convention guardrail (`rg-*`) |

The Function App's Managed Identity has:
- **Owner** on target subscription(s) (for deployments + RBAC)
- **Directory.Read.All** on Microsoft Graph (for Entra ID lookups)

HTTP endpoints are protected by two layers:
- **Azure Function keys** (require `?code=<function-key>` query parameter)
- **Custom API key** (require `X-API-Key: <key>` header when `WEBHOOK_API_KEY` is configured)

---

## Cost Management

| Threshold | Action |
|-----------|--------|
| **$15** (75%) | Warning email to user |
| **90% forecast** | Proactive warning email |
| **$20** (100%) | RBAC → Reader, resources stopped, 5-day grace, then deletion |

---

## Configuration

All settings are managed via Function App Application Settings:

| Setting | Default | Description |
|---------|---------|-------------|
| `ENTRA_GROUP_OBJECT_ID` | _(empty)_ | Security group for auto-provisioning |
| `TARGET_SUBSCRIPTION_IDS` | _(empty)_ | Comma-separated subscription IDs for user RG deployment |
| `MAX_RGS_PER_SUBSCRIPTION` | `950` | Max resource groups per subscription before overflow |
| `WEBHOOK_API_KEY` | _(empty)_ | API key callers must send via `X-API-Key` header |
| `DEFAULT_LOCATION` | `swedencentral` | Azure region |
| `DEFAULT_WARNING_BUDGET` | `15` | Warning threshold (USD) |
| `DEFAULT_HARD_LIMIT_BUDGET` | `20` | Hard limit (USD) |
| `DEFAULT_GRACE_PERIOD_DAYS` | `5` | Days before deletion |
| `SYNC_SCHEDULE` | `0 */10 * * * *` | Group sync frequency |

Per-user overrides can be passed via the HTTP API body.

---

## Copilot Studio Licensing (Optional)

Assign **Microsoft Copilot Studio** per-user licenses independently from sandbox provisioning. Scripts live in the `licensing/` folder and use the Microsoft Graph API via Azure CLI tokens.

```bash
# Check tenant license status
cd licensing
pwsh ./Get-LicenseStatus.ps1

# Preview license assignment (no changes)
pwsh ./Assign-CopilotStudioLicense.ps1 -InputFile "./users.csv" -WhatIf

# Assign licenses
pwsh ./Assign-CopilotStudioLicense.ps1 -InputFile "./users.csv"
```

| Script | Purpose |
|--------|---------|
| `Assign-CopilotStudioLicense.ps1` | Assign Copilot Studio license to users from CSV/JSON |
| `Remove-CopilotStudioLicense.ps1` | Remove Copilot Studio license from users |
| `Get-LicenseStatus.ps1` | Show tenant SKUs and per-user license status (read-only) |

See the full [Copilot Studio Licensing Guide](docs/copilot-studio-licensing.md) for prerequisites, troubleshooting, and integration details.

---

## Integration Examples

### ServiceNow / HR System
POST to `/api/provision` when a new employee is onboarded.

### Power Automate
"When a user is created in Entra ID" → HTTP action → provision endpoint.

### Azure Event Grid
Subscribe to Entra ID audit log events and route to the Function App.

---

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](docs/architecture.md) | Detailed architecture and design decisions |
| [Setup Guide](docs/setup-guide.md) | Step-by-step deployment instructions |
| [Copilot Studio Licensing](docs/copilot-studio-licensing.md) | License assignment scripts and guide |

---

## License

MIT — see [LICENSE](LICENSE).
