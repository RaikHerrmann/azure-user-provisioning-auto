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
│  │  │  Resolve   │──▶│  Create Sub    │──▶│  Deploy      │──▶│ Configure│  │  │
│  │  │  User in   │   │  (if needed,   │  │  Bicep       │  │ Runbooks │  │  │
│  │  │  Entra ID  │   │  via billing)  │  │  Environment │  │ + Webhook│  │  │
│  │  └───────────┘   └────────────────┘  └──────────────┘  └──────────┘  │  │
│  │                                                                       │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Per-User Azure Environment (same as before)               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─── Subscription (under shared billing account) ────────────────────────┐│
│  │  ┌─── Resource Group (rg-{user}) ──────────────────────────────────┐   ││
│  │  │  AI Foundry Hub + Project │ Key Vault │ Storage │ App Insights  │   ││
│  │  │  Automation Account       │ Budget    │ Action Groups           │   ││
│  │  │  Custom RBAC (Sandbox Contributor) │ Policy (naming guardrail)  │   ││
│  │  └────────────────────────────────────────────────────────────────┘   ││
│  └──────────────────────────────────────────────────────────────────────┘││
│                                                                             │
│  Cost Enforcement: $15 warn → $20 enforce → 5-day grace → auto-delete      │
└─────────────────────────────────────────────────────────────────────────────┘
```

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

External systems (HR tools, ServiceNow, custom apps) call the API directly:

```json
POST https://<function-app>.azurewebsites.net/api/provision?code=<function-key>
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

Remove a user's environment when they leave:

```json
POST https://<function-app>.azurewebsites.net/api/deprovision?code=<function-key>
{
    "userPrincipalName": "john.doe@contoso.com",
    "subscriptionId": "xxxx-xxxx"
}
```

## Security

- Function App uses **System-Assigned Managed Identity** — no credentials stored
- HTTP endpoints protected by **function keys** (require `?code=` parameter)
- MI has **Owner** on the target subscription (minimum for RBAC + deployments)
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
