# Architecture

## Overview

This solution replaces the batch CSV-based provisioning model with an **event-driven, fully automated** architecture. No scripts run locally. No admin intervention is needed per user.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Trigger Sources                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────┐   ┌──────────────────┐   ┌────────────────────────┐  │
│  │  HTTP Webhook     │   │  Entra ID Group  │   │  Deprovision API       │  │
│  │  POST /api/       │   │  Timer Sync      │   │  POST /api/            │  │
│  │  provision        │   │  (every 10 min)  │   │  deprovision           │  │
│  └────────┬─────────┘   └────────┬─────────┘   └────────┬───────────────┘  │
│           │                      │                       │                  │
└───────────┼──────────────────────┼───────────────────────┼──────────────────┘
            │                      │                       │
            ▼                      ▼                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│              Azure Function App (PowerShell, Durable Functions)              │
│              Premium Plan (EP1) · Managed Identity · Runs in Azure          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─── Durable Orchestrator ──────────────────────────────────────────────┐  │
│  │                                                                       │  │
│  │   Step 1           Step 2              Step 3            Step 4       │  │
│  │  ┌───────────┐   ┌────────────────┐  ┌──────────────┐  ┌──────────┐  │  │
│  │  │  Resolve   │──▶│  Select Sub    │──▶│  Deploy      │──▶│ Configure│  │  │
│  │  │  User in   │   │  (pick one w/  │  │  Bicep       │  │ Runbooks │  │  │
│  │  │  Entra ID  │   │  available RG  │  │  Environment │  │ + Webhook│  │  │
│  │  └───────────┘   │  capacity)     │  └──────────────┘  └──────────┘  │  │
│  │                   └────────────────┘                                   │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Per-User Azure Environment (same as before)               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─── Subscription(s) (shared, with RG-per-user isolation) ───────────────┐│
│  │  ┌─── rg-user-a ──────────────────────────────────────────────────┐   ││
│  │  │  AI Foundry Hub + Project │ Key Vault │ Storage │ App Insights  │   ││
│  │  │  Automation Account       │ Budget    │ Action Groups           │   ││
│  │  │  Custom RBAC (Sandbox Contributor) │ Policy (naming guardrail)  │   ││
│  │  └────────────────────────────────────────────────────────────────┘   ││
│  │  ┌─── rg-user-b ──────────────────────────────────────────────────┐   ││
│  │  │  ... (same structure, up to MAX_RGS_PER_SUBSCRIPTION)           │   ││
│  │  └────────────────────────────────────────────────────────────────┘   ││
│  └──────────────────────────────────────────────────────────────────────┘││
│                                                                             │
│  Cost Enforcement: $15 warn → $20 enforce → 5-day grace → auto-delete      │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Scaling Model

The solution scales horizontally via **resource groups within shared subscriptions**:

1. Configure one or more target subscriptions in `TARGET_SUBSCRIPTION_IDS`
2. Each new user gets their own resource group (`rg-{sanitized-upn}`) in a subscription with capacity
3. When a subscription reaches `MAX_RGS_PER_SUBSCRIPTION` (default: 950), the next user spills over to the next subscription
4. Azure's limit is ~980 RGs per subscription; the default 950 provides headroom for platform RGs

## What Changed from the Batch Solution

| Aspect | Batch (original) | Event-Driven (this) |
|--------|-----------------|-------------------|
| **Trigger** | Admin edits CSV, runs script | HTTP webhook or Entra ID group membership |
| **Execution** | Local PowerShell or GitHub Actions | Azure Function App (runs in Azure) |
| **Granularity** | All users at once (batch) | One user at a time (on demand) |
| **Admin action** | Edit CSV → run script | Add user to Entra ID group (or POST to API) |
| **Long-running ops** | Sequential script execution | Durable Functions with retry + status tracking |
| **Per-user infra** | Same Bicep modules | Same Bicep modules (unchanged) |
| **Cost controls** | Same ($15/$20 enforcement) | Same ($15/$20 enforcement) |
| **CI/CD** | GitHub Actions deploys users | GitHub Actions deploys platform; platform deploys users |

## Trigger Modes

### 1. HTTP Webhook (POST /api/provision)

External systems (HR tools, ServiceNow, custom apps) call the API directly.
Requires both a **function key** (`?code=`) and an **API key** (`X-API-Key` header):

```json
POST https://<function-app>.azurewebsites.net/api/provision?code=<function-key>
X-API-Key: <your-webhook-api-key>
{
    "userPrincipalName": "john.doe@contoso.com",
    "displayName": "John Doe",
    "email": "john.doe@contoso.com",
    "department": "Engineering"
}
```

Returns `202 Accepted` with orchestration status URLs.

### 2. Entra ID Group Sync (Timer)

Add users to a designated Entra ID security group. The timer function checks every 10 minutes for new members and auto-provisions them. Zero manual steps.

### 3. Deprovision API (POST /api/deprovision)

Remove a user's environment when they leave. The subscription is auto-detected:

```json
POST https://<function-app>.azurewebsites.net/api/deprovision?code=<function-key>
X-API-Key: <your-webhook-api-key>
{
    "userPrincipalName": "john.doe@contoso.com"
}
```

## Security

- Function App uses **System-Assigned Managed Identity** — no credentials stored
- HTTP endpoints protected by **two layers**:
  - **Function keys** (require `?code=` parameter) — built-in Azure Functions auth
  - **Custom API key** (require `X-API-Key` header) — set via `WEBHOOK_API_KEY` app setting
- MI has **Owner** on the target subscription(s) (minimum for RBAC + deployments)
- MI has **Directory.Read.All** on Microsoft Graph (for Entra ID lookups)
- Per-user security model is identical to the batch solution (3-layer protection)

## Durable Functions

The provisioning workflow uses Azure Durable Functions for:
- **Automatic retry** on transient failures (3 attempts per step)
- **Status tracking** via HTTP polling endpoints
- **Reliable execution** of long-running Bicep deployments (5–15 min)
- **Fan-out** capability for future batch scenarios

Each orchestration instance can be monitored via:
```
GET /runtime/webhooks/durableTask/instances/{instanceId}?code=<system-key>
```
