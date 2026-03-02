# Setup Guide

This guide walks through deploying the event-driven provisioning platform from scratch.

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **Azure Subscription** | One or more, with Owner permissions |
| **Entra ID** | Global Reader or User.Read.All (for user lookups) |
| **GitHub Repository** | With Actions enabled |
| **Azure CLI** | ≥ 2.60 (`az --version`) |

---

## Step 1: Create a Service Principal for CI/CD

The GitHub Actions workflow uses federated credentials (no secrets stored).

```bash
# Create the service principal
az ad app create --display-name "UserProvisioningCI"

# Note the appId from the output
APP_ID="<appId-from-output>"

# Create a service principal
az ad sp create --id $APP_ID

# Assign Owner role on the subscription
az role assignment create \
    --assignee $APP_ID \
    --role "Owner" \
    --scope "/subscriptions/<your-subscription-id>"

# Configure federated credential for GitHub Actions
az ad app federated-credential create --id $APP_ID --parameters '{
    "name": "github-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:<your-github-org>/azure-user-provisioning-auto:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
}'

# Also for the production environment
az ad app federated-credential create --id $APP_ID --parameters '{
    "name": "github-production",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:<your-github-org>/azure-user-provisioning-auto:environment:production",
    "audiences": ["api://AzureADTokenExchange"]
}'
```

## Step 2: Configure GitHub Secrets

Add these secrets to your GitHub repository (Settings → Secrets → Actions):

| Secret | Value |
|--------|-------|
| `AZURE_CLIENT_ID` | The `appId` from Step 1 |
| `AZURE_TENANT_ID` | Your Entra ID tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Your Azure subscription ID |

## Step 3: (Optional) Create an Entra ID Security Group

For automatic provisioning via group membership:

```bash
# Create a security group
az ad group create \
    --display-name "AI Sandbox Users" \
    --mail-nickname "ai-sandbox-users" \
    --description "Members of this group get an automatic AI sandbox environment"

# Note the Object ID from the output
GROUP_ID="<objectId-from-output>"
```

## Step 4: Grant Microsoft Graph Permissions

The Function App's Managed Identity needs Graph API access to read users and groups:

```bash
# After deployment, get the MI's Object ID
MI_OBJECT_ID=$(az functionapp identity show \
    --resource-group rg-userprov-platform \
    --name <func-app-name> \
    --query principalId -o tsv)

# Grant Directory.Read.All (requires Global Admin consent)
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"  # Microsoft Graph
DIRECTORY_READ_ALL="7ab1d382-f21e-4acd-a863-ba3e13f7da61"  # Directory.Read.All

az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$MI_OBJECT_ID/appRoleAssignments" \
    --body "{
        \"principalId\": \"$MI_OBJECT_ID\",
        \"resourceId\": \"$(az ad sp show --id $GRAPH_APP_ID --query id -o tsv)\",
        \"appRoleId\": \"$DIRECTORY_READ_ALL\"
    }"
```

## Step 5: Deploy via GitHub Actions

1. Push to `main` branch (or trigger manually via Actions tab)
2. The workflow will:
   - Validate all Bicep templates
   - Deploy platform infrastructure (Function App, Storage, etc.)
   - Compile per-user Bicep templates to ARM JSON
   - Package and deploy the Function App code
   - Configure subscription-level permissions

## Step 6: Test Provisioning

### Option A: HTTP API

```bash
# Get the function key from Azure Portal (Function App → App Keys → default)
FUNC_KEY="<your-function-key>"
API_KEY="<your-webhook-api-key>"
FUNC_URL="https://<func-app-name>.azurewebsites.net"

# Provision a user
curl -X POST "$FUNC_URL/api/provision?code=$FUNC_KEY" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: $API_KEY" \
    -d '{
        "userPrincipalName": "john.doe@contoso.com",
        "displayName": "John Doe",
        "email": "john.doe@contoso.com",
        "department": "Engineering"
    }'

# Response: 202 Accepted with statusQueryGetUri for tracking
```

### Option B: Entra ID Group

```bash
# Add a user to the security group
az ad group member add \
    --group "AI Sandbox Users" \
    --member-id "<user-object-id>"

# The timer function will detect the new member within 10 minutes
# and start provisioning automatically.
```

### Track Orchestration Status

The provision endpoint returns a `statusQueryGetUri`. Poll it to track progress:

```bash
curl "$STATUS_QUERY_URI"
# Returns: { "runtimeStatus": "Running", "output": null, ... }
# When done: { "runtimeStatus": "Completed", "output": { "status": "Succeeded", ... } }
```

## Step 7: (Optional) Configure External Triggers

### ServiceNow Integration

Create a ServiceNow workflow that POSTs to the provision endpoint when a new employee is onboarded.

### Microsoft Power Automate

Create a flow triggered by "When a user is created in Entra ID" that calls the HTTP endpoint.

### Azure Event Grid

Subscribe to Entra ID audit log events for user creation and route to the Function App.

---

## Configuration Reference

All configuration is via Function App **Application Settings** (set during Bicep deployment):

| Setting | Default | Description |
|---------|---------|-------------|
| `ENTRA_GROUP_OBJECT_ID` | _(empty)_ | Entra ID group to sync for auto-provisioning |
| `TARGET_SUBSCRIPTION_IDS` | _(empty)_ | Comma-separated subscription IDs for user RG deployment |
| `MAX_RGS_PER_SUBSCRIPTION` | `950` | Max RGs per subscription (Azure limit: ~980) |
| `WEBHOOK_API_KEY` | _(empty)_ | API key callers must provide via `X-API-Key` header |
| `DEFAULT_LOCATION` | `swedencentral` | Azure region for user environments |
| `DEFAULT_WARNING_BUDGET` | `15` | Warning threshold (USD) |
| `DEFAULT_HARD_LIMIT_BUDGET` | `20` | Hard limit (USD) |
| `DEFAULT_GRACE_PERIOD_DAYS` | `5` | Grace period before deletion |
| `SYNC_SCHEDULE` | `0 */10 * * * *` | NCRONTAB schedule for group sync |

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Function App not starting | Check Application Insights logs; verify `requirements.psd1` modules resolved |
| User not found in Entra ID | Ensure MI has `Directory.Read.All`; check user exists in tenant |
| Deployment fails | Check MI has Owner on the target subscription |
| Timer not firing | Verify `SYNC_SCHEDULE` and `ENTRA_GROUP_OBJECT_ID` are set |
| All subscriptions full | Add more subscription IDs to `TARGET_SUBSCRIPTION_IDS` |
| Orchestration stuck | Check Durable Functions task hub in Storage Account (`UserProvisioningHub*` tables) |
