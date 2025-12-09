<#
.SYNOPSIS
    Setup GitHub Actions OIDC authentication for Azure
    
.DESCRIPTION
    This script configures Azure AD App Registration with federated credentials
    for passwordless GitHub Actions authentication using OpenID Connect (OIDC).
    
.PARAMETER GitHubUsername
    Your GitHub username (required)
    
.PARAMETER GitHubRepo
    Your GitHub repository name (required)
    
.EXAMPLE
    ./setup-github-oidc.ps1 -GitHubUsername "ainanihsan" -GitHubRepo "Azure-Communication-Service-Voice-API"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$GitHubUsername,
    
    [Parameter(Mandatory=$true)]
    [string]$GitHubRepo
)

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  GitHub Actions OIDC Setup for Azure" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# STEP 1: Create App Registration
Write-Host "[1/4] Creating Azure AD App Registration..." -ForegroundColor Yellow
$APP_ID = az ad app create --display-name "github-oidc-ACS-Voice-API" --query appId -o tsv

if (-not $APP_ID) {
    Write-Error "Failed to create app registration"
    exit 1
}

Write-Host "✓ App Registration created" -ForegroundColor Green
Write-Host "  Client ID: $APP_ID" -ForegroundColor White
Write-Host ""

# STEP 2: Get Azure IDs
Write-Host "[2/4] Getting Azure tenant and subscription IDs..." -ForegroundColor Yellow
$TENANT_ID = az account show --query tenantId -o tsv
$SUBSCRIPTION_ID = az account show --query id -o tsv

Write-Host "✓ Tenant ID: $TENANT_ID" -ForegroundColor Green
Write-Host "✓ Subscription ID: $SUBSCRIPTION_ID" -ForegroundColor Green
Write-Host ""

# STEP 3: Create Federated Credential
Write-Host "[3/4] Creating federated credential for GitHub OIDC..." -ForegroundColor Yellow

$federatedConfig = @{
    name = "github-oidc-main-branch"
    issuer = "https://token.actions.githubusercontent.com"
    subject = "repo:$GitHubUsername/${GitHubRepo}:ref:refs/heads/main"
    audiences = @("api://AzureADTokenExchange")
} | ConvertTo-Json

$federatedConfig | Out-File -FilePath "federated.json" -Encoding utf8

try {
    az ad app federated-credential create --id $APP_ID --parameters federated.json | Out-Null
    Write-Host "✓ Federated credential created" -ForegroundColor Green
    Write-Host "  Repository: $GitHubUsername/$GitHubRepo" -ForegroundColor White
    Write-Host "  Branch: main" -ForegroundColor White
} catch {
    Write-Error "Failed to create federated credential: $_"
    exit 1
} finally {
    Remove-Item "federated.json" -ErrorAction SilentlyContinue
}
Write-Host ""

# STEP 4: Assign Azure Roles
Write-Host "[4/4] Assigning Azure roles to service principal..." -ForegroundColor Yellow

try {
    az role assignment create `
        --assignee $APP_ID `
        --role "Contributor" `
        --scope "/subscriptions/$SUBSCRIPTION_ID" `
        --only-show-errors | Out-Null
    Write-Host "✓ Contributor role assigned" -ForegroundColor Green
    
    az role assignment create `
        --assignee $APP_ID `
        --role "User Access Administrator" `
        --scope "/subscriptions/$SUBSCRIPTION_ID" `
        --only-show-errors | Out-Null
    Write-Host "✓ User Access Administrator role assigned" -ForegroundColor Green
} catch {
    Write-Warning "Role assignment may have failed or already exists: $_"
}
Write-Host ""

# Display GitHub Secrets Configuration
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  GitHub Secrets Configuration" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Add these secrets to your GitHub repository:" -ForegroundColor Yellow
Write-Host "  Settings → Secrets and variables → Actions → New repository secret" -ForegroundColor Gray
Write-Host ""
Write-Host "  Secret Name              Value" -ForegroundColor White
Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor Gray
Write-Host "  AZURE_CLIENT_ID          $APP_ID" -ForegroundColor White
Write-Host "  AZURE_TENANT_ID          $TENANT_ID" -ForegroundColor White
Write-Host "  AZURE_SUBSCRIPTION_ID    $SUBSCRIPTION_ID" -ForegroundColor White
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "✓ Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Add the three secrets to your GitHub repository" -ForegroundColor White
Write-Host "  2. Go to Actions tab in GitHub" -ForegroundColor White
Write-Host "  3. Run 'Provision and Deploy (OIDC)' workflow" -ForegroundColor White
Write-Host ""
