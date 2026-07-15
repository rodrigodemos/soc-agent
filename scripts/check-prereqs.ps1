<#
.SYNOPSIS
    Preflight checks for the soc-agent template — run before `azd provision` / `azd up`.

.DESCRIPTION
    Validates that your workstation, Azure context, and target environment are
    ready to deploy this template. Walks through tooling, auth, subscription
    state, required resource-provider registrations, region + model quota, and
    any BYO resources you've configured via azd environment variables.

    The script never modifies anything by default. Pass `-RegisterProviders` to
    register missing RPs in-place.

.PARAMETER Location
    Azure region to validate quota / region availability against.
    Defaults to the AZURE_LOCATION azd env var (or `eastus2` if neither is set).

.PARAMETER ModelName
    Foundry model deployment to check quota for.
    Defaults to AZURE_AI_MODEL_DEPLOYMENT_NAME or `gpt-5.4`.

.PARAMETER ModelSku
    Model SKU. Defaults to MODEL_SKU or `GlobalStandard`.

.PARAMETER ModelCapacity
    Required model deployment capacity (TPM). Defaults to MODEL_CAPACITY or `500`.

.PARAMETER RegisterProviders
    Register any missing resource providers automatically.

.PARAMETER Quiet
    Suppress per-check chatter; only emit warnings, failures, and the summary.

.EXAMPLE
    .\scripts\check-prereqs.ps1

.EXAMPLE
    .\scripts\check-prereqs.ps1 -Location westus3 -ModelCapacity 100 -RegisterProviders
#>
[CmdletBinding()]
param(
    [string]$Location,
    [string]$ModelName,
    [string]$ModelSku,
    [int]   $ModelCapacity,
    [switch]$RegisterProviders,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'   # keep going so users see ALL issues at once

# ── Output helpers ──────────────────────────────────────────────────────────

$script:Passed   = 0
$script:Warnings = 0
$script:Errors   = 0

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host -ForegroundColor White "══ $Title "
}

function Write-Check {
    param(
        [ValidateSet('Pass','Warn','Fail','Info')] [string]$Kind,
        [string]$Name,
        [string]$Detail = ''
    )
    switch ($Kind) {
        'Pass' { $script:Passed++ }
        'Warn' { $script:Warnings++ }
        'Fail' { $script:Errors++ }
    }
    if ($Quiet -and $Kind -in 'Pass','Info') { return }
    $icon  = @{ Pass = '[ OK ]'; Warn = '[WARN]'; Fail = '[FAIL]'; Info = '[INFO]' }[$Kind]
    $color = @{ Pass = 'Green';  Warn = 'Yellow'; Fail = 'Red';   Info = 'Cyan'   }[$Kind]
    Write-Host -NoNewline -ForegroundColor $color "$icon  "
    if ($Detail) { Write-Host "$Name`n        $Detail" } else { Write-Host $Name }
}

function Test-Command {
    param([string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-VersionFromOutput {
    param([string]$Text, [string]$Pattern)
    if ($Text -match $Pattern) { return [Version]$Matches[1] }
    return $null
}

function Compare-Version {
    param([Version]$Actual, [Version]$Minimum)
    return ($Actual -ge $Minimum)
}

# ── 0. Resolve effective parameters from azd env if available ───────────────

# Try to read the azd env. We do this best-effort — the script must run even
# if azd is not installed yet (we'll flag that separately).
$azdEnvValues = @{}
if (Test-Command azd) {
    try {
        $kv = & azd env get-values 2>$null
        foreach ($line in $kv) {
            if ($line -match '^([A-Z_][A-Z0-9_]*)="?(.*?)"?$') {
                $azdEnvValues[$Matches[1]] = $Matches[2]
            }
        }
    } catch { }  # no env yet — first run
}

if (-not $Location)      { $Location      = if ($azdEnvValues['AZURE_LOCATION'])      { $azdEnvValues['AZURE_LOCATION'] }      else { 'eastus2' } }
if (-not $ModelName)     { $ModelName     = if ($azdEnvValues['AZURE_AI_MODEL_DEPLOYMENT_NAME']) { $azdEnvValues['AZURE_AI_MODEL_DEPLOYMENT_NAME'] } else { 'gpt-5.4' } }
if (-not $ModelSku)      { $ModelSku      = if ($azdEnvValues['MODEL_SKU'])           { $azdEnvValues['MODEL_SKU'] }           else { 'GlobalStandard' } }
if (-not $ModelCapacity) { $ModelCapacity = if ($azdEnvValues['MODEL_CAPACITY'])      { [int]$azdEnvValues['MODEL_CAPACITY'] } else { 500 } }

Write-Host ''
Write-Host -ForegroundColor White 'soc-agent — preflight checks'
Write-Host -ForegroundColor DarkGray ('Effective settings:  Location={0}  Model={1}  SKU={2}  Capacity={3}' -f $Location, $ModelName, $ModelSku, $ModelCapacity)

# ── 1. Tooling ──────────────────────────────────────────────────────────────

Write-Section 'Tooling'

# Azure CLI ≥ 2.60
if (Test-Command az) {
    try {
        $azJson = & az version --output json 2>$null | ConvertFrom-Json
        if ($azJson.'azure-cli') {
            $azVer = [Version]$azJson.'azure-cli'
        }
    } catch { $azVer = $null }
    if ($azVer -and (Compare-Version $azVer ([Version]'2.60.0'))) {
        Write-Check Pass 'Azure CLI'  "version $azVer"
    } elseif ($azVer) {
        Write-Check Warn 'Azure CLI'  "version $azVer — minimum recommended is 2.60.0 (run: az upgrade)"
    } else {
        Write-Check Warn 'Azure CLI'  'installed but version could not be determined'
    }
} else {
    Write-Check Fail 'Azure CLI'  'not found — install from https://aka.ms/installazurecli'
}

# Azure Developer CLI ≥ 1.10
if (Test-Command azd) {
    $azdText = (& azd version 2>$null) -join "`n"
    $azdVer = $null
    if ($azdText -match 'azd version (\d+\.\d+\.\d+)') {
        $azdVer = [Version]$Matches[1]
    }
    if ($azdVer -and (Compare-Version $azdVer ([Version]'1.10.0'))) {
        Write-Check Pass 'Azure Developer CLI'  "version $azdVer"
    } elseif ($azdVer) {
        Write-Check Warn 'Azure Developer CLI'  "version $azdVer — minimum recommended is 1.10.0 (run: winget upgrade Microsoft.Azd  or  brew upgrade azd)"
    } else {
        Write-Check Warn 'Azure Developer CLI'  'installed but version could not be determined'
    }
} else {
    Write-Check Fail 'Azure Developer CLI'  'not found — install from https://aka.ms/azd-install'
}

# Bicep
if (Test-Command az) {
    $bicepText = (& az bicep version 2>$null) -join "`n"
    $bicepVer = $null
    if ($bicepText -match 'Bicep CLI version (\d+\.\d+\.\d+)') {
        $bicepVer = [Version]$Matches[1]
    }
    if ($bicepVer) {
        Write-Check Pass 'Bicep CLI'  "version $bicepVer (via az)"
    } else {
        Write-Check Warn 'Bicep CLI'  'not installed for az — run: az bicep install'
    }
}

# Docker (only required on the host that runs `azd deploy`)
if (Test-Command docker) {
    $dockerOk = $false
    try {
        $null = & docker info 2>$null
        $dockerOk = ($LASTEXITCODE -eq 0)
    } catch { }
    if ($dockerOk) {
        Write-Check Pass 'Docker'  'daemon is running'
    } else {
        Write-Check Warn 'Docker'  'CLI present but daemon is not reachable — azd deploy will fail on this host'
    }
} else {
    Write-Check Warn 'Docker'  'not installed — required only on the host that runs `azd deploy` (the in-VNet host for this template)'
}

# Git
if (Test-Command git) {
    Write-Check Info 'git'  ((& git --version) -join '')
}

# ── 2. Auth ─────────────────────────────────────────────────────────────────

Write-Section 'Azure auth'

$account = $null
if (Test-Command az) {
    try {
        $account = & az account show --output json 2>$null | ConvertFrom-Json
    } catch { }

    if ($account) {
        Write-Check Pass 'az signed in'  ('user={0}, tenant={1}' -f $account.user.name, $account.tenantId)
        Write-Check Info 'Active subscription'  ('{0} ({1})' -f $account.name, $account.id)
    } else {
        Write-Check Fail 'az signed in'  'not signed in — run: az login'
    }
}

if (Test-Command azd) {
    $azdAuth = & azd auth login --check-status 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Check Pass 'azd signed in'  'logged in via azd'
    } else {
        Write-Check Warn 'azd signed in'  'not logged in — run: azd auth login'
    }
}

# ── 3. Resource providers ───────────────────────────────────────────────────

Write-Section 'Resource provider registration'

$requiredProviders = @(
    'Microsoft.KeyVault'
    'Microsoft.CognitiveServices'
    'Microsoft.Storage'
    'Microsoft.Search'
    'Microsoft.Network'
    'Microsoft.App'
    'Microsoft.ContainerService'
    'Microsoft.ContainerRegistry'
    'Microsoft.DocumentDB'
    'Microsoft.OperationalInsights'
    'Microsoft.Insights'
)

if ($account) {
    $registered = & az provider list --query "[].{ns:namespace,state:registrationState}" --output json 2>$null | ConvertFrom-Json
    $regMap = @{}
    foreach ($p in $registered) { $regMap[$p.ns] = $p.state }

    $missing = @()
    foreach ($ns in $requiredProviders) {
        $state = $regMap[$ns]
        switch ($state) {
            'Registered'   { Write-Check Pass $ns   'Registered' }
            'Registering'  { Write-Check Warn $ns   'Registering (in progress) — wait until Registered' }
            default        {
                Write-Check Fail $ns ("state=$state — run: az provider register --namespace $ns")
                $missing += $ns
            }
        }
    }

    if ($RegisterProviders -and $missing.Count -gt 0) {
        Write-Host -ForegroundColor Yellow ('Registering {0} missing provider(s)...' -f $missing.Count)
        foreach ($ns in $missing) {
            & az provider register --namespace $ns --output none
            Write-Host "  - $ns registration requested"
        }
        Write-Host -ForegroundColor Yellow 'Re-run this script in a few minutes to confirm registration completed.'
    } elseif ($missing.Count -gt 0) {
        Write-Check Info 'Tip' 're-run with -RegisterProviders to register the missing ones automatically'
    }
} else {
    Write-Check Info 'Resource providers'  'skipped — not signed in'
}

# ── 4. Region & model quota ─────────────────────────────────────────────────

Write-Section 'Region & quota'

    # Allowed regions are the union from infra/bicep/main.bicep and the upstream sample.
$allowedRegions = @(
    'westus','westus2','westus3','eastus','eastus2','southcentralus','northcentralus',
    'canadacentral','canadaeast','brazilsouth','francecentral','germanywestcentral',
    'italynorth','spaincentral','swedencentral','switzerlandnorth','norwayeast',
    'polandcentral','uksouth','westeurope','uaenorth','southafricanorth',
    'japaneast','koreacentral','southeastasia','southindia','australiaeast'
)
if ($allowedRegions -contains $Location.ToLower()) {
    Write-Check Pass 'Region allowed'  "$Location is in main.bicep's allow-list"
} else {
    Write-Check Fail 'Region allowed'  "$Location is NOT in main.bicep's allow-list — pick one of: $($allowedRegions -join ', ')"
}

if ($account) {
    # Foundry model quota check via Cognitive Services usages
    $usageJson = & az cognitiveservices usage list --location $Location --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $usageJson) {
        $usages = $usageJson | ConvertFrom-Json
        # SKU name shape: e.g., "OpenAI.GlobalStandard.gpt-5.4"
        $skuName = "OpenAI.$ModelSku.$ModelName"
        $match = $usages | Where-Object { $_.name.value -eq $skuName }
        if ($match) {
            $used = [int]$match.currentValue
            $cap  = [int]$match.limit
            $free = $cap - $used
            if ($free -ge $ModelCapacity) {
                Write-Check Pass 'Model quota'  ("$skuName — used $used / limit $cap (need $ModelCapacity, have $free free)")
            } else {
                Write-Check Fail 'Model quota'  ("$skuName — used $used / limit $cap; need $ModelCapacity, only $free free. Request quota in the Azure portal.")
            }
        } else {
            Write-Check Warn 'Model quota'  "could not find quota entry for '$skuName' in $Location — verify the model + SKU are available in this region"
        }
    } else {
        Write-Check Warn 'Model quota'  'failed to read cognitiveservices usage (insufficient permissions?) — verify manually before provisioning'
    }

    # Backend-service regional availability checks. These help catch the
    # "InsufficientResourcesAvailable" failures that cause auto-caphost
    # creation to fail with misleading "vnet not found" errors. We verify
    # each service is listed as available in this region. (We can't check
    # subscription-level capacity headroom from CLI — that's only visible
    # at provision time.)
    $foundryServices = @(
        @{ Name = 'Cosmos DB';   Provider = 'Microsoft.DocumentDB';     ResourceType = 'databaseAccounts' }
        @{ Name = 'AI Search';   Provider = 'Microsoft.Search';         ResourceType = 'searchServices' }
        @{ Name = 'Storage';     Provider = 'Microsoft.Storage';        ResourceType = 'storageAccounts' }
        @{ Name = 'AI Services'; Provider = 'Microsoft.CognitiveServices'; ResourceType = 'accounts' }
    )
    foreach ($svc in $foundryServices) {
        $locsJson = & az provider show --namespace $svc.Provider --query "resourceTypes[?resourceType=='$($svc.ResourceType)'].locations[]" --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $locsJson) {
            Write-Check Warn ("Region availability: $($svc.Name)") "could not read regions for $($svc.Provider)/$($svc.ResourceType)"
            continue
        }
        $locs = ($locsJson | ConvertFrom-Json) | ForEach-Object { ($_ -replace ' ', '').ToLower() }
        if ($locs -contains $Location.ToLower()) {
            Write-Check Pass ("Region availability: $($svc.Name)") "$Location is supported"
        } else {
            Write-Check Fail ("Region availability: $($svc.Name)") "$Location is NOT supported by $($svc.Provider)/$($svc.ResourceType). Pick a region where all 4 services are available."
        }
    }

    # Best-effort regional capacity hint. Microsoft doesn't expose a CLI
    # endpoint that says "this region is full for Cosmos DB right now", but
    # we can flag the most heavily loaded regions so users can avoid them.
    $crowdedRegions = @('eastus2','eastus','westus','westus2')
    if ($crowdedRegions -contains $Location.ToLower()) {
        Write-Check Warn 'Region capacity hint' ("{0} is consistently among the most loaded Foundry regions. If 'azd provision' fails with 'InsufficientResourcesAvailable', switch to westus3 / swedencentral / australiaeast (see docs/TROUBLESHOOTING.md)." -f $Location)
    }
}

# ── 5. azd environment + BYO resource checks ────────────────────────────────

Write-Section 'azd environment & BYO resources'

if ($azdEnvValues.Count -eq 0) {
    Write-Check Info 'azd env'  'no azd environment loaded — run `azd init` and `azd env select <name>` first if you have one'
} else {
    $envName = $azdEnvValues['AZURE_ENV_NAME']
    Write-Check Info 'azd env'  ('environment={0}, {1} variables loaded' -f $envName, $azdEnvValues.Count)
}

# Required azd env vars (auto-set by the preprovision hook if missing)
$envAzureSub = $azdEnvValues['AZURE_SUBSCRIPTION_ID']
if ($envAzureSub) {
    if ($account -and $envAzureSub -ne $account.id) {
        Write-Check Warn 'AZURE_SUBSCRIPTION_ID'  ("azd env points at $envAzureSub but `az` is signed in to $($account.id) — set the right one with: azd env set AZURE_SUBSCRIPTION_ID <id>")
    } else {
        Write-Check Pass 'AZURE_SUBSCRIPTION_ID'  $envAzureSub
    }
} elseif ($account) {
    Write-Check Info 'AZURE_SUBSCRIPTION_ID'  ("not set yet — the preprovision hook will auto-bind to {0} ({1})" -f $account.name, $account.id)
} else {
    Write-Check Fail 'AZURE_SUBSCRIPTION_ID'  'not set, and `az` is not signed in — run: az login'
}

$envAzureLoc = $azdEnvValues['AZURE_LOCATION']
if ($envAzureLoc) {
    Write-Check Pass 'AZURE_LOCATION'  $envAzureLoc
} else {
    Write-Check Info 'AZURE_LOCATION'  'not set yet — the preprovision hook will prompt at `azd provision` time (default: eastus2)'
}

function Test-ExistingResource {
    param([string]$EnvVar, [string]$Label)
    $rid = $azdEnvValues[$EnvVar]
    if (-not $rid) { return }   # not configured — nothing to check
    $exists = & az resource show --ids $rid --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Check Pass $Label  "exists: $rid"
        return $rid
    } else {
        Write-Check Fail $Label  "configured but not found / no access: $rid"
        return $null
    }
}

$null = Test-ExistingResource 'EXISTING_VNET_RESOURCE_ID'                       'BYO VNet'
$agentSubnetId = Test-ExistingResource 'EXISTING_AGENT_SUBNET_RESOURCE_ID'      'BYO Agent subnet'
$null = Test-ExistingResource 'EXISTING_PE_SUBNET_RESOURCE_ID'                  'BYO PE subnet'
$null = Test-ExistingResource 'EXISTING_MCP_SUBNET_RESOURCE_ID'                 'BYO MCP subnet'
$null = Test-ExistingResource 'EXISTING_AI_SEARCH_RESOURCE_ID'                  'BYO AI Search'
$null = Test-ExistingResource 'EXISTING_AZURE_STORAGE_ACCOUNT_RESOURCE_ID'      'BYO Storage account'
$null = Test-ExistingResource 'EXISTING_AZURE_COSMOS_DB_ACCOUNT_RESOURCE_ID'    'BYO Cosmos DB account'

# Verify the Agent subnet is exclusively delegated to Microsoft.App/environments
if ($agentSubnetId) {
    $subnet = & az network vnet subnet show --ids $agentSubnetId --output json 2>$null | ConvertFrom-Json
    if ($subnet) {
        $delegations = @($subnet.delegations | ForEach-Object { $_.serviceName })
        if ($delegations.Count -eq 1 -and $delegations[0] -eq 'Microsoft.App/environments') {
            Write-Check Pass 'Agent subnet delegation'  'exclusively delegated to Microsoft.App/environments'
        } elseif ($delegations.Count -eq 0) {
            Write-Check Fail 'Agent subnet delegation'  'subnet has NO delegation — must be delegated to Microsoft.App/environments'
        } else {
            Write-Check Fail 'Agent subnet delegation'  ("subnet delegated to: $($delegations -join ', ') — must be EXCLUSIVELY Microsoft.App/environments")
        }
        if ($subnet.ipConfigurations -or $subnet.privateEndpoints) {
            Write-Check Warn 'Agent subnet usage'  'subnet appears to contain other resources — agent subnet must be empty before provisioning'
        }
    }
}

# Developer IP allowlist (informational)
if ($azdEnvValues['DEVELOPER_IP_CIDR']) {
    Write-Check Info 'DEVELOPER_IP_CIDR'  ("set to {0} — ACR will be public with deny-all + this allow rule. Clear for production." -f $azdEnvValues['DEVELOPER_IP_CIDR'])
}

# ── 6. Local repo sanity ────────────────────────────────────────────────────

Write-Section 'Repository'

$repoRoot = Split-Path -Parent $PSScriptRoot

# Detect the active IaC provider from azure.yaml so we validate the right stack
$activeProvider = 'bicep'
$activeInfraPath = 'infra'
$azureYamlPath = Join-Path $repoRoot 'azure.yaml'
if (Test-Path $azureYamlPath) {
    $ay = Get-Content -Raw $azureYamlPath
    if ($ay -match '(?ms)^\s*infra:\s*.*?provider:\s*(\S+).*?path:\s*\./?(\S+)') {
        $activeProvider  = $Matches[1]
        $activeInfraPath = $Matches[2]
    }
}
Write-Check Info 'IaC provider'  ("azure.yaml → provider={0}, path={1}" -f $activeProvider, $activeInfraPath)

$commonFiles = @('azure.yaml','src\copilot-agent\main.py','src\mcp-http-server\app\main.py')
$providerFiles = if ($activeProvider -eq 'terraform') {
    @("$activeInfraPath\main.tf", "$activeInfraPath\variables.tf", "$activeInfraPath\outputs.tf", "$activeInfraPath\main.tfvars.json")
} else {
    @("$activeInfraPath\main.bicep", "$activeInfraPath\main.parameters.json")
}
foreach ($f in ($commonFiles + $providerFiles)) {
    $p = Join-Path $repoRoot $f
    if (Test-Path $p) { Write-Check Pass "found: $f" } else { Write-Check Fail "missing: $f" }
}

# Validate the active IaC stack
if ($activeProvider -eq 'terraform') {
    if (Test-Command terraform) {
        Push-Location (Join-Path $repoRoot $activeInfraPath)
        try {
            $tfInit = & terraform init -input=false -backend=false 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                Write-Check Fail 'Terraform init' 'terraform init failed — see terraform init output'
            } else {
                $tfVal = & terraform validate 2>&1 | Out-String
                if ($LASTEXITCODE -eq 0) {
                    Write-Check Pass 'Terraform validate'  "$activeInfraPath validates without errors"
                } else {
                    Write-Check Fail 'Terraform validate'  ("failed:`n$tfVal")
                }
            }
        } finally {
            Pop-Location
        }
    } else {
        Write-Check Warn 'Terraform CLI' 'not installed — install from https://developer.hashicorp.com/terraform/install to validate locally'
    }
} else {
    # Bicep
    if (Test-Command az) {
        $tmp = New-TemporaryFile
        & az bicep build --file (Join-Path $repoRoot "$activeInfraPath\main.bicep") --outfile $tmp 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Check Pass 'Bicep compile'  "$activeInfraPath\main.bicep built without errors"
        } else {
            Write-Check Fail 'Bicep compile'  "$activeInfraPath\main.bicep failed to build — run: az bicep build --file $activeInfraPath\main.bicep"
        }
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

# ── Summary ─────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host -ForegroundColor White '═══════════════════════════════════════════════════════'
Write-Host -ForegroundColor Green  ("  Passed:   {0}" -f $script:Passed)
Write-Host -ForegroundColor Yellow ("  Warnings: {0}" -f $script:Warnings)
Write-Host -ForegroundColor Red    ("  Failures: {0}" -f $script:Errors)
Write-Host -ForegroundColor White '═══════════════════════════════════════════════════════'

if ($script:Errors -gt 0) {
    Write-Host -ForegroundColor Red "`nResolve the failures above before running 'azd provision' or 'azd up'."
    exit 1
} elseif ($script:Warnings -gt 0) {
    Write-Host -ForegroundColor Yellow "`nReady to provision, but review the warnings above first."
    exit 0
} else {
    Write-Host -ForegroundColor Green "`nAll checks passed — you're good to run 'azd up' (or 'azd provision' + 'azd deploy' for the split path)."
    exit 0
}
