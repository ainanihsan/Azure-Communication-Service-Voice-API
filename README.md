# Azure Communication Service - Setup Guide

This project provisions Azure resources for an Azure Communication Service voice calling demo and deploys an Azure Function App.

## Prerequisites

- Azure subscription with Contributor access
- Azure CLI installed and logged in (`az login`)
- .NET 8.0 SDK
- PowerShell 7+ (for running scripts)

## Quick Start (Local Development)

### 1. Provision Azure Resources

```powershell
cd scripts
./provision.ps1
```

This script will:
- Create a resource group
- Provision Azure Communication Service, Storage Account, Key Vault, and Function App
- Store the ACS connection string in Key Vault
- Output resource details to `outputs.json`

**Note:** The script uses **fixed resource names** for idempotency. If resources already exist, it will reuse them.

### 2. Build and Deploy Function App

```powershell
cd FunctionApp/FunctionAppACS
dotnet restore
dotnet build
dotnet publish -c Release -o ./publish

# Deploy (manual)
az functionapp deployment source config-zip `
  -g rg-acs-demo-cli `
  -n fn-acs-demo-cli-001 `
  --src ./publish.zip
```

## GitHub Actions Setup (Optional)

To enable automated deployment via GitHub Actions:

### 1. Create Azure Service Principal for OIDC

```powershell
# Replace with your values
$subscriptionId = "<YOUR_SUBSCRIPTION_ID>"
$githubOrg = "<YOUR_GITHUB_USERNAME>"
$githubRepo = "<YOUR_REPO_NAME>"

# Create app registration
az ad app create --display-name "GitHub-Actions-OIDC"

# Get the app ID
$appId = az ad app list --display-name "GitHub-Actions-OIDC" --query "[0].appId" -o tsv

# Create service principal
az ad sp create --id $appId

# Create federated credential for GitHub Actions
az ad app federated-credential create `
  --id $appId `
  --parameters '{
    "name": "GitHubActions",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:'$githubOrg'/'$githubRepo':ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

### 2. Grant Permissions to Service Principal

```powershell
cd scripts

# Run the setup script with your service principal's client ID
./setup-github-permissions.ps1 -ClientId $appId
```

### 3. Configure GitHub Secrets

Add these secrets to your GitHub repository (Settings → Secrets and variables → Actions):

- `AZURE_CLIENT_ID`: Your service principal's App ID
- `AZURE_TENANT_ID`: Your Azure tenant ID (`az account show --query tenantId -o tsv`)
- `AZURE_SUBSCRIPTION_ID`: Your subscription ID

### 4. Run GitHub Actions Workflow

Go to Actions → "Provision and Deploy (OIDC)" → Run workflow

## Resource Names

The following fixed names are used (can be customized in `scripts/provision.ps1`):

- Resource Group: `rg-acs-demo-cli`
- ACS: `acs-demo-cli-prod`
- Storage: `stacsdemo001`
- Key Vault: `kv-acs-demo-cli-001`
- Function App: `fn-acs-demo-cli-001`

## Testing the Function

After deployment, test the MakeCall function:

```powershell
# Get function key
$key = az functionapp function keys list `
  -g rg-acs-demo-cli `
  -n fn-acs-demo-cli-001 `
  --function-name MakeCall `
  --query default -o tsv

# Call the function
$url = "https://fn-acs-demo-cli-001.azurewebsites.net/api/MakeCall?code=$key"

Invoke-RestMethod -Uri $url -Method POST -Body '{"to":"+1234567890","from":"+0987654321"}' -ContentType "application/json"
```

## Troubleshooting

### Permission Errors in GitHub Actions

If you see "AuthorizationFailed" errors, ensure the service principal has these roles:
- **Contributor** (Resource Group scope)
- **User Access Administrator** (Resource Group scope)
- **Key Vault Secrets Officer** (Key Vault scope)

Run `./scripts/setup-github-permissions.ps1` to grant these automatically.

### Resources Already Exist

The provision script is idempotent - it will reuse existing resources with the same names. To start fresh, delete the resource group:

```powershell
az group delete -n rg-acs-demo-cli --yes
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                 Azure Resources                      │
├─────────────────────────────────────────────────────┤
│                                                      │
│  ┌────────────────────┐      ┌──────────────────┐  │
│  │ Azure Communication│      │   Key Vault      │  │
│  │     Service        │      │  (RBAC enabled)  │  │
│  │                    │      │                  │  │
│  │ • Phone Numbers    │◄─────┤ • ACS Connection │  │
│  │ • Voice Calling    │      │   String         │  │
│  └────────────────────┘      └──────────────────┘  │
│           ▲                            ▲            │
│           │                            │            │
│           │    ┌──────────────────┐   │            │
│           │    │  Function App    │   │            │
│           └────┤  (.NET 8)        │───┘            │
│                │                  │                 │
│                │ • MakeCall API   │                 │
│                │ • Managed        │                 │
│                │   Identity       │                 │
│                └──────────────────┘                 │
│                         ▲                           │
│                         │                           │
└─────────────────────────┼───────────────────────────┘
                          │
                    HTTP Request
                          │
                   ┌──────┴──────┐
                   │   Client    │
                   └─────────────┘
```
