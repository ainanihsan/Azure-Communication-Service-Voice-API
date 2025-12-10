# Azure Communication Service - Voice API Demo

This project demonstrates Infrastructure as Code (IaC) for Azure Communication Service with automated deployment using GitHub Actions. It provisions Azure resources and deploys a Function App that can make outbound calls via ACS Voice API.

## 📋 Project Requirements

✅ **Infrastructure as Code**: Automated Azure resource provisioning  
✅ **CI/CD Pipeline**: GitHub Actions workflow with OIDC authentication  
✅ **Voice API Integration**: Function App to invoke ACS for outbound calls  
✅ **Security Best Practices**: Managed Identity, Key Vault, RBAC, no hardcoded secrets  
✅ **Monitoring & Logging**: Application Insights integration with ACS diagnostics

## 🛠️ Why PowerShell/Azure CLI Instead of Terraform?

This project uses **PowerShell with Azure CLI** for infrastructure provisioning rather than Terraform for the following reasons:

1. **Native Azure Integration**: Azure CLI provides first-class support for all Azure services including ACS, with immediate access to new features
2. **Simpler Setup**: No Terraform state management, backend configuration, or provider versioning
3. **Easier Debugging**: Direct, readable commands that can be run independently for troubleshooting
4. **Idempotent Scripts**: The provision script checks for existing resources and reuses them
5. **Scripting Flexibility**: PowerShell enables complex logic, error handling, and Azure AD integration
6. **Cross-Platform**: Works on Windows, Linux, and macOS with PowerShell Core

**Note**: This approach is production-ready and follows Azure best practices. For organizations requiring Terraform, the PowerShell logic can be easily translated to HCL.

## Prerequisites

- Azure subscription with Contributor access
- Azure CLI installed and logged in (`az login`)
- .NET 8.0 SDK (for local development)
- PowerShell 7+ (for running scripts)
- GitHub account

## 🚀 Quick Start (Local Development)

If you just want to test locally without GitHub Actions:

### 1. Provision Azure Resources

```powershell
cd scripts
./provision.ps1
```

This script will:
- Create a resource group
- Provision Azure Communication Service, Storage Account, Key Vault, and Function App
- Store the ACS connection string in Key Vault
- Configure managed identity and RBAC permissions
- Output resource details to `outputs.json`

**Note:** Uses fixed resource names for idempotency. Safe to run multiple times.

### 2. Build and Deploy Function App

```powershell
cd FunctionApp/FunctionAppACS
dotnet restore
dotnet build
dotnet publish -c Release -o ./publish

# Create deployment package
Compress-Archive -Path publish\* -DestinationPath deploy.zip -Force

# Deploy to Azure
az functionapp deployment source config-zip `
  -g rg-acs-demo-cli `
  -n fn-acs-demo-cli-001 `
  --src ./deploy.zip
```

## 🔐 GitHub Actions Setup (CI/CD Pipeline)

### Overview
The GitHub Actions workflow uses **OpenID Connect (OIDC)** for secure, passwordless authentication to Azure. This eliminates the need for storing credentials as secrets.

### Step 1: Create Azure AD App Registration

```powershell
# Create the app registration
$APP_ID = az ad app create --display-name "github-oidc-ACS-Voice-API" --query appId -o tsv

Write-Host "✓ App Registration created"
Write-Host "Client ID: $APP_ID" -ForegroundColor Yellow
```

### Step 2: Create Federated Credential for GitHub OIDC

```powershell
# Get your tenant ID
$TENANT_ID = az account show --query tenantId -o tsv

# Create federated credential configuration
# IMPORTANT: Replace 'ainanihsan' with YOUR GitHub username
# IMPORTANT: Replace 'Azure-Communication-Service-Voice-API' with YOUR repo name
@"
{
  "name": "github-oidc-main-branch",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:YOUR_GITHUB_USERNAME/YOUR_REPO_NAME:ref:refs/heads/main",
  "audiences": [
    "api://AzureADTokenExchange"
  ]
}
"@ | Out-File -FilePath federated.json -Encoding utf8

# Create the federated credential
az ad app federated-credential create `
  --id $APP_ID `
  --parameters federated.json

# Verify it was created
az ad app federated-credential list --id $APP_ID -o table

Write-Host "✓ Federated credential created" -ForegroundColor Green
```

### Step 3: Assign Azure Roles to Service Principal

```powershell
# Get your subscription ID
$subscriptionId = az account show --query id -o tsv

# The $APP_ID from Step 1 is your service principal's client ID
# Assign Contributor role (for creating/managing resources)
az role assignment create `
  --assignee $APP_ID `
  --role "Contributor" `
  --scope "/subscriptions/$subscriptionId"

# Assign User Access Administrator role (for assigning roles to managed identities)
az role assignment create `
  --assignee $APP_ID `
  --role "User Access Administrator" `
  --scope "/subscriptions/$subscriptionId"

Write-Host "✓ Roles assigned to service principal" -ForegroundColor Green
```

### Step 4: Configure GitHub Secrets

Go to your GitHub repository:
- **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

Add these three secrets:

| Secret Name | Value | How to Get |
|-------------|-------|------------|
| `AZURE_CLIENT_ID` | Your App ID from Step 1 | `echo $APP_ID` |
| `AZURE_TENANT_ID` | Your Azure tenant ID | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | Your subscription ID | `az account show --query id -o tsv` |

```powershell
# Display values for GitHub Secrets
Write-Host "`nGitHub Secrets Configuration:" -ForegroundColor Cyan
Write-Host "AZURE_CLIENT_ID: $APP_ID" -ForegroundColor White
Write-Host "AZURE_TENANT_ID: $TENANT_ID" -ForegroundColor White
Write-Host "AZURE_SUBSCRIPTION_ID: $subscriptionId" -ForegroundColor White
```

### Step 5: Run the Workflow

1. Go to your GitHub repository
2. Click **Actions** tab
3. Select **"Provision and Deploy (OIDC)"** workflow
4. Click **"Run workflow"** → **"Run workflow"**

The workflow will:
- ✅ Authenticate to Azure using OIDC (no passwords!)
- ✅ Provision all Azure resources
- ✅ Build and deploy the Function App
- ✅ Configure app settings
- ✅ Run smoke tests

## 📖 Complete Setup Script (Copy-Paste Ready)

For convenience, here's a complete script you can run:

```powershell
# ===== GitHub Actions OIDC Setup Script =====

Write-Host "Setting up GitHub Actions OIDC for Azure..." -ForegroundColor Cyan

# STEP 1: Create App Registration
Write-Host "`n[1/4] Creating Azure AD App Registration..." -ForegroundColor Yellow
$APP_ID = az ad app create --display-name "github-oidc-ACS-Voice-API" --query appId -o tsv
Write-Host "✓ Client ID: $APP_ID" -ForegroundColor Green

# STEP 2: Get IDs
$TENANT_ID = az account show --query tenantId -o tsv
$SUBSCRIPTION_ID = az account show --query id -o tsv

# STEP 3: Create Federated Credential
Write-Host "`n[2/4] Creating federated credential..." -ForegroundColor Yellow
Write-Host "⚠️  IMPORTANT: Update the 'subject' field with YOUR GitHub username and repo name!" -ForegroundColor Red

@"
{
  "name": "github-oidc-main-branch",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:YOUR_GITHUB_USERNAME/YOUR_REPO_NAME:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}
"@ | Out-File -FilePath federated.json -Encoding utf8

Write-Host "Please edit federated.json and update YOUR_GITHUB_USERNAME and YOUR_REPO_NAME"
Write-Host "Press Enter when ready to continue..."
Read-Host

az ad app federated-credential create --id $APP_ID --parameters federated.json
Write-Host "✓ Federated credential created" -ForegroundColor Green

# STEP 4: Assign Roles
Write-Host "`n[3/4] Assigning Azure roles..." -ForegroundColor Yellow
az role assignment create --assignee $APP_ID --role "Contributor" --scope "/subscriptions/$SUBSCRIPTION_ID"
az role assignment create --assignee $APP_ID --role "User Access Administrator" --scope "/subscriptions/$SUBSCRIPTION_ID"
Write-Host "✓ Roles assigned" -ForegroundColor Green

# STEP 5: Display GitHub Secrets
Write-Host "`n[4/4] GitHub Secrets Configuration:" -ForegroundColor Cyan
Write-Host "Add these secrets to your GitHub repository (Settings → Secrets and variables → Actions):"
Write-Host ""
Write-Host "AZURE_CLIENT_ID      = $APP_ID" -ForegroundColor White
Write-Host "AZURE_TENANT_ID      = $TENANT_ID" -ForegroundColor White
Write-Host "AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION_ID" -ForegroundColor White
Write-Host ""
Write-Host "✓ Setup complete! You can now run the GitHub Actions workflow." -ForegroundColor Green
```

Save this as `scripts/setup-github-oidc.ps1` and run it.

## 🔒 Security Best Practices Implemented

### 1. **No Hardcoded Secrets**
- ✅ Uses Azure Managed Identity for Function App
- ✅ ACS connection string stored in Key Vault
- ✅ GitHub Actions uses OIDC (no service principal passwords)

### 2. **Least Privilege Access**
- ✅ Function App has only "Key Vault Secrets Officer" role
- ✅ Key Vault uses RBAC authorization (not access policies)
- ✅ Service principal has minimal required roles

### 3. **Secret Management**
- ✅ Key Vault for sensitive data (ACS connection string)
- ✅ Environment variables for configuration (KEY_VAULT_URI)
- ✅ No secrets in source code or logs

### 4. **Federated Identity**
- ✅ OIDC eliminates credential storage in GitHub
- ✅ Short-lived tokens per workflow run
- ✅ Scoped to specific repository and branch

## 🏗️ Architecture

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

## 📞 Testing the Voice API

After deployment, test the MakeCall function:

```powershell
# Get the function key
$FN = "fn-acs-demo-cli-001"
$RG = "rg-acs-demo-cli"

$key = az functionapp function keys list `
  -g $RG `
  -n $FN `
  --function-name MakeCall `
  --query default -o tsv

# Call the function with phone numbers in E.164 format
$url = "https://$FN.azurewebsites.net/api/MakeCall?code=$key"

$body = @{
  to = "+1234567890"    # Destination phone number
  from = "+0987654321"  # Your ACS phone number
} | ConvertTo-Json

Invoke-RestMethod -Uri $url -Method POST -Body $body -ContentType "application/json"
```

**Note:** You need to:
1. Acquire a phone number in your ACS resource via Azure Portal
2. Use that number in the `from` field
3. Use a valid destination number in the `to` field

**Expected Result**: The function will return a 500 Internal Server Error if you haven't configured actual phone numbers in ACS. This is normal and indicates the function is working correctly but lacks valid phone configuration.

## 📊 Monitoring & Logging

### Automatic Configuration

The provision script automatically configures:

1. **Application Insights** - Created and linked to the Function App
2. **ACS Diagnostic Settings** - Logs sent to Application Insights
3. **Function App Logging** - All invocations and errors tracked

### View Logs

**Function App Logs** (Azure Portal):
1. Navigate to your Function App → **Monitoring** → **Logs** or **Log stream**
2. View real-time execution logs and errors

**Application Insights** (Azure Portal):
1. Navigate to Application Insights → **Logs**
2. Query example:
   ```kusto
   traces
   | where timestamp > ago(1h)
   | where message contains "MakeCall"
   | order by timestamp desc
   ```

**ACS Call Logs** (Azure Portal):
1. Navigate to Communication Service → **Monitoring** → **Logs**
2. Query example:
   ```kusto
   ACSCallAutomationIncomingOperations
   | where TimeGenerated > ago(1h)
   | project TimeGenerated, OperationName, ResultType, ResultDescription
   | order by TimeGenerated desc
   ```

### PowerShell Commands

```powershell
# Stream Function App logs
az functionapp log tail -g rg-acs-demo-cli -n fn-acs-demo-cli-001

# Query Application Insights
$AI_ID = az monitor app-insights component show -g rg-acs-demo-cli --app fn-acs-demo-cli-001-insights --query id -o tsv
az monitor app-insights query --app $AI_ID --analytics-query "traces | where timestamp > ago(1h) | limit 10"
```

### Metrics to Monitor

- **Function Execution Count**: Track API invocations
- **Function Execution Duration**: Performance monitoring
- **Function Failures**: Error rate tracking
- **ACS Call Success Rate**: Voice call completion
- **ACS Call Duration**: Average call length
- **Key Vault Access**: Secret retrieval success/failures

All metrics are automatically collected and available in Application Insights.

## 📁 Project Structure

```
├── .github/
│   └── workflows/
│       └── main.yml                    # GitHub Actions CI/CD workflow
├── FunctionApp/
│   └── FunctionAppACS/
│       └── FunctionAppACS/
│           ├── MakeCall.cs             # Voice API function
│           ├── Program.cs              # Function host configuration
│           ├── FunctionAppACS.csproj   # Project file
│           └── local.settings.json     # Local development settings
├── scripts/
│   ├── provision.ps1                   # Azure resource provisioning
│   ├── setup-github-permissions.ps1    # Permission setup helper
│   └── outputs.json                    # Provisioned resource details
└── README.md                           # This file
```
