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

- Own subscription + resource group (isolated from other users)
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
                              │                          │ ──▶ │ Subscription      │
  Entra ID Group Sync ──────▶ │  1. Resolve User          │     │ ├── Resource Group│
  (timer, every 10 min)       │  2. Create Subscription   │     │ │   ├── AI Foundry│
                              │  3. Deploy Bicep (IaC)    │     │ │   ├── Budget    │
  POST /api/deprovision ────▶ │  4. Configure Runbooks    │     │ │   ├── Automation│
                              │                          │     │ │   └── RBAC      │
                              └──────────────────────────┘     └──────────────────┘
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
| `AZURE_SUBSCRIPTION_ID` | Target subscription ID |

Then push to `main` or trigger the workflow manually.

See the [Setup Guide](docs/setup-guide.md) for detailed steps.

### 2. Provision Users

**Option A — API call** (from any system):
```bash
curl -X POST "https://<func-app>.azurewebsites.net/api/provision?code=<key>" \
  -H "Content-Type: application/json" \
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
curl -X POST "https://<func-app>.azurewebsites.net/api/deprovision?code=<key>" \
  -H "Content-Type: application/json" \
  -d '{"userPrincipalName": "john.doe@contoso.com", "subscriptionId": "xxx"}'
```

---

## What Changed from the Batch Solution

| Aspect | Before (Batch) | Now (Event-Driven) |
|--------|---------------|-------------------|
| Admin workflow | Edit CSV → run script locally | Add user to Entra ID group (or integrate with HR system) |
| Where it runs | Admin's machine / GitHub Actions runner | Azure Function App (always running in Azure) |
| Trigger | Manual script execution | HTTP webhook / timer / Entra ID group change |
| Granularity | Batch (all users at once) | Single user (on demand) |
| Long-running ops | Sequential PowerShell | Durable Functions (retry, status tracking) |
| Per-user infra | Bicep modules | Same Bicep modules (unchanged) |

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
│   ├── Activity-CreateSubscription/         # Activity: subscription creation
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
├── .github/workflows/
│   └── deploy.yml                           # CI/CD: deploy platform + functions
├── docs/
│   ├── architecture.md                      # Detailed architecture
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
- **Owner** on the target subscription (for deployments + RBAC)
- **Directory.Read.All** on Microsoft Graph (for Entra ID lookups)

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
| `BILLING_SCOPE` | _(empty)_ | For automatic subscription creation |
| `DEFAULT_LOCATION` | `swedencentral` | Azure region |
| `DEFAULT_WARNING_BUDGET` | `15` | Warning threshold (USD) |
| `DEFAULT_HARD_LIMIT_BUDGET` | `20` | Hard limit (USD) |
| `DEFAULT_GRACE_PERIOD_DAYS` | `5` | Days before deletion |
| `SYNC_SCHEDULE` | `0 */10 * * * *` | Group sync frequency |

Per-user overrides can be passed via the HTTP API body.

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

---

## License

MIT — see [LICENSE](LICENSE).
