<#
.SYNOPSIS
    Complete Azure resource provisioning for ACS demo
    
.DESCRIPTION
    Idempotent PowerShell + Azure CLI provisioning script.
    Works for both local development and GitHub Actions.
    
    For local use: Run after 'az login' with your account
    For GitHub Actions: Requires service principal with proper permissions
    
.NOTES
    What it does:
    - Register required Azure resource providers
    - Create resource group
    - Provision Azure Communication Service
    - Create storage account
    - Create Key Vault with RBAC enabled
    - Fetch ACS primary key and store connection string in Key Vault
    - Create Function App with system assigned identity
    - Assign Key Vault Secrets Officer role to Function identity
    - Write outputs.json
    
    Uses fixed resource names for idempotency - safe to run multiple times.
    If permission errors occur, role assignments will be skipped with warnings.
#>

# ---------- Config - edit before running if you want ----------
$rg       = "rg-acs-demo-cli"
$location = "swedencentral"        # canonical location token
$acsName  = "acs-demo-cli-$((Get-Random -Maximum 99999))"
$acsDataLocation = "europe"        # ACS data location token
$storage  = ("stacsdemo" + (Get-Random -Maximum 999999)).ToLower()
$kvName   = "kv-acs-demo-cli-$((Get-Random -Maximum 99999))"
$funcName = "fn-acs-demo-cli-$((Get-Random -Maximum 9999))"
$apiVer   = "2025-05-01"
$outputs  = Join-Path $PSScriptRoot "outputs.json"

# ---------- Helpers ----------
function Write-Ok($m){ Write-Host "[OK]  $m" -ForegroundColor Green }
function Write-Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err($m){ Write-Host "[ERR]  $m" -ForegroundColor Red }

function Poll-ProviderRegistered($ns, $timeoutSec) {
  $start = Get-Date
  while ((Get-Date) -lt $start.AddSeconds($timeoutSec)) {
    $state = az provider show --namespace $ns --query registrationState -o tsv 2>$null
    if ($state -eq "Registered") { return $true }
    Start-Sleep -Seconds 5
  }
  return $false
}

# ---------- Begin ----------
Write-Host "Provision script starting. Ensure you ran az login in this shell."

# Ensure active subscription available
$subId = (az account show --query id -o tsv).Trim()
if (-not $subId) {
  Write-Err "No active subscription detected. Run 'az login' and select a subscription then re-run."
  exit 1
}
Write-Info "Active subscription: $subId"

# 1) Register providers
$providers = @("Microsoft.Storage","Microsoft.KeyVault","Microsoft.Web","Microsoft.Communication")
foreach ($p in $providers) {
  Write-Info "Checking provider $p"
  $state = az provider show --namespace $p --query registrationState -o tsv 2>$null
  if ($state -ne "Registered") {
    Write-Info "Registering $p"
    az provider register --namespace $p | Out-Null
    if (-not (Poll-ProviderRegistered $p 180)) {
      Write-Warn "Provider $p did not become Registered within timeout. You may need admin help or wait longer."
    } else {
      Write-Ok "Provider $p Registered"
    }
  } else {
    Write-Ok "Provider $p already Registered"
  }
}

# 2) Resource group
Write-Info "Creating or validating resource group $rg in $location"
az group create --name $rg --location $location | Out-Null
Write-Ok "Resource group ready"

# 3) Create Azure Communication Service (data-location must be supported token)
Write-Info "Ensuring Azure Communication Service $acsName (data-location: $acsDataLocation)"
try {
  $acsExists = az communication show --name $acsName --resource-group $rg --only-show-errors 2>$null
} catch { $acsExists = $null }
if (-not $acsExists) {
  az communication create --name $acsName --resource-group $rg --location global --data-location norway | Out-Null
  Write-Ok "ACS created: $acsName"
} else {
  Write-Ok "ACS already exists: $acsName"
}

# 4) Create storage account
Write-Info "Ensuring storage account $storage"
$sa = az storage account show -n $storage -g $rg 2>$null
if (-not $sa) {
  az storage account create --name $storage --resource-group $rg --location $location --sku Standard_LRS | Out-Null
  Write-Ok "Storage account created: $storage"
} else {
  Write-Ok "Storage account exists: $storage"
}

# 5) Create Key Vault with RBAC enabled
Write-Info "Ensuring Key Vault $kvName with RBAC authorization"
$kv = az keyvault show -n $kvName -g $rg 2>$null
if (-not $kv) {
  az keyvault create --name $kvName --resource-group $rg --location $location --enable-rbac-authorization true | Out-Null
  Write-Ok "Key Vault created with RBAC: $kvName"
} else {
  Write-Ok "Key Vault exists: $kvName"
}

# 6) Fetch ACS primary key and build connection string
Write-Info "Attempting to retrieve ACS keys for $acsName"
$uri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Communication/communicationServices/$acsName/listKeys?api-version=$apiVer"
try {
  $restOut = az rest --method post --uri $uri -o json | ConvertFrom-Json
  $primaryKey = $restOut.primaryKey
  if (-not $primaryKey) {
    Write-Warn "Primary key not returned. You may need to fetch it manually from the portal."
    $acsConn = $null
  } else {
    $acsEndpoint = "https://$acsName.communication.azure.com"
    $acsConn = "endpoint=$acsEndpoint;accesskey=$primaryKey"
    Write-Ok "Fetched ACS primary key"
  }
} catch {
  Write-Warn "Failed to call listKeys API. If permissions block this, fetch the primary key manually from the portal Keys blade."
  $acsConn = $null
}

# 7) Create Function App with system assigned identity
Write-Info "Ensuring Function App $funcName"
$fa = az functionapp show -n $funcName -g $rg 2>$null
if (-not $fa) {
  az functionapp create --resource-group $rg --consumption-plan-location $location --name $funcName --storage-account $storage --runtime dotnet-isolated --runtime-version 8 --functions-version 4 --assign-identity --os-type Windows | Out-Null
  Write-Ok "Function App created: $funcName"
} else {
  Write-Ok "Function App exists: $funcName"
}

# 8) Get ids
$funcPrincipalId = az functionapp identity show --name $funcName -g $rg --query principalId -o tsv
$vaultId = az keyvault show -n $kvName -g $rg --query id -o tsv
Write-Host "Function principalId: $funcPrincipalId"
Write-Host "Vault id: $vaultId"

# Wait for the Function system-assigned identity to appear in AAD as a service principal
# This prevents race conditions where RBAC assignment fails because the SP record is not yet in AAD
$spReady = $false
for ($wait = 0; $wait -lt 12; $wait++) {
  try {
    az ad sp show --id $funcPrincipalId -o none
    $spReady = $true
    break
  } catch {
    Start-Sleep -Seconds 5
  }
}
if (-not $spReady) {
  Write-Warn "Function identity service principal not found in AAD after waiting. Role assignment may fail or need longer propagation."
} else {
  Write-Ok "Function identity present in AAD"
}

# 9) Assign Key Vault data role to Function identity
if ($funcPrincipalId) {
  # Check if role is already assigned
  $existingRole = az role assignment list --assignee $funcPrincipalId --scope $vaultId --role "Key Vault Secrets Officer" -o json 2>$null | ConvertFrom-Json
  
  if ($existingRole -and $existingRole.Count -gt 0) {
    Write-Ok "Key Vault Secrets Officer role already assigned"
    $assigned = $true
  } else {
    Write-Info "Assigning Key Vault Secrets Officer to Function id at vault scope"
    
    # Try assignment with retries to allow AAD propagation
    $assigned = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
      try {
        az role assignment create --assignee-object-id $funcPrincipalId --assignee-principal-type ServicePrincipal --role "Key Vault Secrets Officer" --scope $vaultId --only-show-errors 2>&1 | Out-Null
        Write-Ok "Role assignment created"
        $assigned = $true
        break
      } catch {
        $errorMsg = $_.Exception.Message
        if ($errorMsg -like "*AuthorizationFailed*" -or $errorMsg -like "*does not have authorization*") {
          Write-Warn "Service principal lacks permission to assign roles. Skipping - assign manually if needed."
          Write-Info "Run: az role assignment create --assignee-object-id $funcPrincipalId --assignee-principal-type ServicePrincipal --role 'Key Vault Secrets Officer' --scope $vaultId"
          break
        }
        if ($attempt -lt 3) {
          Write-Warn "Role assignment attempt $attempt failed. Retrying..."
          Start-Sleep -Seconds (5 * $attempt)
        }
      }
    }
  }  if (-not $assigned) {
    Write-Warn "Could not assign role to function identity after multiple attempts. The identity may not have propagated to AAD or your caller lacks permission to assign roles."
  } else {
    # verify assignment visible
    $propagated = $false
    for ($i=0; $i -lt 24; $i++) {
      Start-Sleep -Seconds 5
      $ra = az role assignment list --assignee $funcPrincipalId --scope $vaultId -o json | ConvertFrom-Json
      if ($ra.Count -gt 0) { $propagated = $true; break }
    }
    if ($propagated) { Write-Ok "Role assignment visible" } else { Write-Warn "Role assignment not visible yet. You may need to wait or retry." }
  }
} else {
  Write-Warn "Function principal id not available, skipping role assignment. Re-run after identity appears."
}

# 10) If we have ACS connection string, store it in Key Vault
$secretStored = $false
if ($acsConn) {
  Write-Info "Attempting to store ACS connection string in Key Vault secret 'AcsConnectionString'"

  # Determine caller object id so we can perform a temporary data-plane elevation if needed
  $callerObjectId = $null
  try {
    $callerObjectId = az ad signed-in-user show --query id -o tsv 2>$null
  } catch { $callerObjectId = $null }

  if (-not $callerObjectId) {
    try {
      $acctUser = az account show --query user.name -o tsv 2>$null
      if ($acctUser) {
        $callerObjectId = az ad sp show --id $acctUser --query objectId -o tsv 2>$null
      }
    } catch { $callerObjectId = $null }
  }

  if (-not $callerObjectId) {
    Write-Warn "Could not determine caller object id. Attempting to set secret directly."
    try {
      az keyvault secret set --vault-name $kvName -n "AcsConnectionString" --value $acsConn --only-show-errors 2>&1 | Out-Null
      Write-Ok "Stored AcsConnectionString in Key Vault"
      $secretStored = $true
    } catch {
      Write-Warn "Could not store secret - RBAC permission issue. Secret must be set manually or grant 'Key Vault Secrets Officer' role to the caller."
      Write-Info "Manual command: az keyvault secret set --vault-name $kvName -n AcsConnectionString --value '<CONNECTION_STRING>'"
      $secretStored = $false
    }
  } else {
    # Check whether caller already has the Key Vault Secrets Officer role at the vault scope
    $hasRole = 0
    try {
      $hasRole = az role assignment list --assignee $callerObjectId --scope $vaultId --query "[?roleDefinitionName=='Key Vault Secrets Officer'] | length(@)" -o tsv 2>$null
      if (-not $hasRole) { $hasRole = 0 }
    } catch { $hasRole = 0 }

    $createdTempAssignment = $false
    if ($hasRole -eq 0) {
      Write-Info "Granting temporary Key Vault Secrets Officer role to current caller"
      try {
        az role assignment create --assignee $callerObjectId --role "Key Vault Secrets Officer" --scope $vaultId | Out-Null
        $createdTempAssignment = $true
        Write-Ok "Temporary role assignment created for caller"
      } catch {
        Write-Warn "Temporary role assignment failed or already exists. Will attempt to set secret anyway."
      }

      # allow propagation
      Start-Sleep -Seconds 20
    } else {
      Write-Info "Caller already has Key Vault Secrets Officer role"
    }

    # Attempt to set the secret
    try {
      az keyvault secret set --vault-name $kvName -n "AcsConnectionString" --value $acsConn | Out-Null
      Write-Ok "Stored AcsConnectionString in Key Vault"
      $secretStored = $true
    } catch {
      Write-Warn "Could not store secret. Error: $($_.Exception.Message)"
      Write-Info "If this persists, tenant deny assignments or policies may be blocking the operation."
    }

    # Clean up temporary role if we created it
    if ($createdTempAssignment) {
      try {
        az role assignment delete --assignee $callerObjectId --role "Key Vault Secrets Officer" --scope $vaultId | Out-Null
        Write-Ok "Temporary role assignment removed"
      } catch {
        Write-Warn "Failed to delete temporary role assignment. Remove it manually if necessary."
      }
    }
  }
} else {
  Write-Warn "ACS connection string not available to store. Copy primary key from portal and store manually if needed."
}

# 11) Configure Function App setting for KV URI
Write-Info "Setting KEY_VAULT_URI application setting on Function App"
$kvUri = "https://$kvName.vault.azure.net/"
az functionapp config appsettings set `
    --name $funcName `
    --resource-group $rg `
    --settings KEY_VAULT_URI=$kvUri | Out-Null
Write-Ok "Configured KEY_VAULT_URI for Function App"


# 12) Save outputs
$output = @{
  subscriptionId = $subId
  resourceGroup = $rg
  location = $location
  acs = @{ name = $acsName; dataLocation = $acsDataLocation; endpoint = "https://$acsName.communication.azure.com" }
  storage = @{ name = $storage }
  keyVault = @{ name = $kvName; id = $vaultId }
  functionApp = @{ name = $funcName; principalId = $funcPrincipalId }
  secretStored = $secretStored
}
$output | ConvertTo-Json -Depth 8 | Out-File -FilePath $outputs -Encoding UTF8
Write-Ok "Wrote outputs to $outputs"

Write-Ok "Provision complete. Inspect outputs.json and verify resources in the portal or via az show commands."
