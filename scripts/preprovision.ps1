<#
.SYNOPSIS
    azd preprovision hook — interactive setup for AZURE_SUBSCRIPTION_ID,
    AZURE_LOCATION, and the Foundry model deployment.

.DESCRIPTION
    Runs automatically before `azd provision` / `azd up` (wired in `azure.yaml`).

    On first run, prompts the user to choose:
      * Azure subscription (numbered menu, default = current `az` context)
      * Azure region (numbered menu, default = eastus2)
      * Foundry model name / version / SKU / capacity (with defaults)

    All choices are persisted as azd environment variables. The chosen model
    is also written into `azure.yaml`'s `deployments:` block (between the
    SOC_AGENT_MODEL_DEPLOYMENT markers) because the `azure.ai.agents` extension
    parses that block as typed JSON and azd's `${VAR=default}` substitution
    always produces strings — which fails type-checking on `capacity` (int).

    On subsequent runs the hook detects the env vars are already set and
    skips all prompts. To force a re-prompt:
        azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME ""    # re-prompt model
        azd env set AZURE_LOCATION ""                    # re-prompt region
        azd env set AZURE_SUBSCRIPTION_ID ""              # re-prompt subscription
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ── Helpers ─────────────────────────────────────────────────────────────────

function Get-AzdEnvMap {
    $map = @{}
    $lines = & azd env get-values 2>$null
    foreach ($line in $lines) {
        if ($line -match '^([A-Z_][A-Z0-9_]*)="?(.*?)"?$') {
            $map[$Matches[1]] = $Matches[2]
        }
    }
    return $map
}

function Read-Choice {
    <#
    Numbered-menu picker. Accepts a number, an exact value match, or Enter
    to accept the default. Re-prompts on invalid input.
    #>
    param(
        [string] $Title,
        [array]  $Options,     # array of @{ Display = '...'; Value = '...' }
        [string] $Default = ''
    )
    Write-Host ''
    Write-Host -ForegroundColor Cyan $Title
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $marker = if ($Default -and ($Options[$i].Value -eq $Default)) { '  (default)' } else { '' }
        Write-Host ('  [{0,2}] {1}{2}' -f ($i+1), $Options[$i].Display, $marker)
    }
    while ($true) {
        $hint = if ($Default) { " [Enter = default]" } else { '' }
        $resp = Read-Host ("Pick 1-{0}{1}" -f $Options.Count, $hint)
        if ([string]::IsNullOrWhiteSpace($resp)) {
            if ($Default) { return $Default }
            Write-Host -ForegroundColor Yellow 'No default available — please pick a number.'
            continue
        }
        if ($resp -match '^\d+$') {
            $idx = [int]$resp - 1
            if ($idx -ge 0 -and $idx -lt $Options.Count) { return $Options[$idx].Value }
        }
        $match = $Options | Where-Object { $_.Value -eq $resp }
        if ($match) { return $match[0].Value }
        Write-Host -ForegroundColor Yellow "Invalid choice. Try again."
    }
}

function Read-WithDefault {
    param([string]$Prompt, [string]$Default)
    $resp = Read-Host ("{0} [{1}]" -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($resp)) { return $Default }
    return $resp
}

function Update-ModelDeploymentBlock {
    <#
    Rewrites the deployments block in azure.yaml between the
    SOC_AGENT_MODEL_DEPLOYMENT markers with the chosen model values.
    #>
    param(
        [string]$AzureYamlPath,
        [string]$ModelFormat,
        [string]$ModelName,
        [string]$ModelVersion,
        [string]$ModelSku,
        [int]   $ModelCapacity
    )
    $content = Get-Content -Raw -LiteralPath $AzureYamlPath
    $beginMark = '# >>> SOC_AGENT_MODEL_DEPLOYMENT'
    $endMark   = '# <<< SOC_AGENT_MODEL_DEPLOYMENT <<<'

    if ($content -notmatch [regex]::Escape($beginMark)) {
        Write-Warning "azure.yaml is missing the SOC_AGENT_MODEL_DEPLOYMENT markers; skipping in-place edit. Update the deployments block manually."
        return
    }

    $newBlock = @"
        # >>> SOC_AGENT_MODEL_DEPLOYMENT — managed by scripts/preprovision (do not edit manually) >>>
        - model:
            format: $ModelFormat
            name: $ModelName
            version: "$ModelVersion"
          name: $ModelName
          sku:
            capacity: $ModelCapacity
            name: $ModelSku
        # <<< SOC_AGENT_MODEL_DEPLOYMENT <<<
"@
    $pattern = '(?ms)[ \t]*# >>> SOC_AGENT_MODEL_DEPLOYMENT.*?# <<< SOC_AGENT_MODEL_DEPLOYMENT <<<'
    $patched = [regex]::Replace($content, $pattern, $newBlock)
    Set-Content -LiteralPath $AzureYamlPath -Value $patched -NoNewline
}

# ── 1. Subscription ─────────────────────────────────────────────────────────

$envMap = Get-AzdEnvMap

if ([string]::IsNullOrWhiteSpace($envMap['AZURE_SUBSCRIPTION_ID'])) {
    Write-Host -ForegroundColor Cyan "`nFetching subscriptions you have access to..."
    try {
        $subs = & az account list --query "[?state=='Enabled']" --output json 2>$null | ConvertFrom-Json
    } catch { $subs = $null }
    if (-not $subs -or $subs.Count -eq 0) {
        Write-Error 'No enabled Azure subscriptions found. Run `az login` and try again.'
        exit 1
    }
    $currentSub = & az account show --query id --output tsv 2>$null
    $opts = $subs | ForEach-Object {
        [pscustomobject]@{
            Display = ("{0,-40}  {1}" -f $_.name, $_.id)
            Value   = $_.id
        }
    }
    $picked = Read-Choice -Title 'Select an Azure subscription' -Options $opts -Default $currentSub
    & azd env set AZURE_SUBSCRIPTION_ID $picked | Out-Null
    & az account set --subscription $picked 2>$null | Out-Null
    Write-Host -ForegroundColor Green "AZURE_SUBSCRIPTION_ID = $picked"
} else {
    Write-Host -ForegroundColor DarkGray ("AZURE_SUBSCRIPTION_ID already set: {0}" -f $envMap['AZURE_SUBSCRIPTION_ID'])
}

# ── 2. Region ───────────────────────────────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($envMap['AZURE_LOCATION'])) {
    # Must match the allowed list in infra/main.bicep
    $regions = @(
        'eastus2','eastus','westus2','westus3','westus','southcentralus','northcentralus',
        'canadacentral','canadaeast','brazilsouth','francecentral','germanywestcentral',
        'italynorth','spaincentral','swedencentral','switzerlandnorth','norwayeast',
        'polandcentral','uksouth','westeurope','uaenorth','southafricanorth',
        'japaneast','koreacentral','southeastasia','southindia','australiaeast'
    )
    $opts = $regions | ForEach-Object { [pscustomobject]@{ Display = $_; Value = $_ } }
    $picked = Read-Choice -Title 'Select an Azure region' -Options $opts -Default 'eastus2'
    & azd env set AZURE_LOCATION $picked | Out-Null
    Write-Host -ForegroundColor Green "AZURE_LOCATION = $picked"
} else {
    Write-Host -ForegroundColor DarkGray ("AZURE_LOCATION already set: {0}" -f $envMap['AZURE_LOCATION'])
}

# ── 3. Foundry model deployment ─────────────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($envMap['AZURE_AI_MODEL_DEPLOYMENT_NAME'])) {
    Write-Host ''
    Write-Host -ForegroundColor Cyan 'Foundry model deployment (Enter accepts the default in brackets):'

    $modelName     = Read-WithDefault 'Model name'      'gpt-4o-mini'
    $modelVersion  = Read-WithDefault 'Model version'   '2024-07-18'
    $modelFormat   = Read-WithDefault 'Model format'    'OpenAI'
    $modelSku      = Read-WithDefault 'Model SKU'       'GlobalStandard'
    $capacityStr   = Read-WithDefault 'Model capacity (TPM)' '30'
    if (-not [int]::TryParse($capacityStr, [ref]$null)) {
        Write-Error "Model capacity must be an integer (got: '$capacityStr')."
        exit 1
    }
    $modelCapacity = [int]$capacityStr

    & azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME $modelName    | Out-Null
    & azd env set MODEL_VERSION                  $modelVersion | Out-Null
    & azd env set MODEL_FORMAT                   $modelFormat  | Out-Null
    & azd env set MODEL_SKU                      $modelSku     | Out-Null
    & azd env set MODEL_CAPACITY                 $modelCapacity| Out-Null

    $azureYamlPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'azure.yaml')).Path
    Update-ModelDeploymentBlock `
        -AzureYamlPath $azureYamlPath `
        -ModelFormat   $modelFormat   `
        -ModelName     $modelName     `
        -ModelVersion  $modelVersion  `
        -ModelSku      $modelSku      `
        -ModelCapacity $modelCapacity

    Write-Host -ForegroundColor Green ("Model deployment set: {0} ({1} {2}, {3} TPM)" -f $modelName, $modelFormat, $modelVersion, $modelCapacity)
    Write-Host -ForegroundColor DarkGray '(azure.yaml deployments block has been updated with your selection.)'
} else {
    Write-Host -ForegroundColor DarkGray ("Model deployment already set: {0}" -f $envMap['AZURE_AI_MODEL_DEPLOYMENT_NAME'])
}

