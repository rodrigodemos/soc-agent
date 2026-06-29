<#
.SYNOPSIS
    azd preprovision hook — auto-bind required env vars from the active Azure CLI context.

.DESCRIPTION
    Runs automatically before `azd provision` / `azd up` (wired in `azure.yaml`).
    The `azure.ai.agents` azd extension this template uses requires
    AZURE_SUBSCRIPTION_ID to be present in the azd env before provisioning;
    this hook reads the subscription from `az account show` and sets it for
    you so you don't have to.

    AZURE_LOCATION is prompted interactively if missing.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

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

$env = Get-AzdEnvMap

# ── AZURE_SUBSCRIPTION_ID ───────────────────────────────────────────────────

if (-not $env['AZURE_SUBSCRIPTION_ID']) {
    try {
        $account = & az account show --output json 2>$null | ConvertFrom-Json
    } catch { $account = $null }

    if (-not $account) {
        Write-Error 'AZURE_SUBSCRIPTION_ID is not set in the azd env, and `az account show` failed. Sign in with `az login` and re-run.'
        exit 1
    }

    Write-Host -ForegroundColor Cyan ("Binding azd env to subscription: {0} ({1})" -f $account.name, $account.id)
    & azd env set AZURE_SUBSCRIPTION_ID $account.id | Out-Null
} else {
    Write-Host -ForegroundColor DarkGray ("AZURE_SUBSCRIPTION_ID already set: {0}" -f $env['AZURE_SUBSCRIPTION_ID'])
}

# ── AZURE_LOCATION ──────────────────────────────────────────────────────────

if (-not $env['AZURE_LOCATION']) {
    $default = 'eastus2'
    $input = Read-Host -Prompt ("AZURE_LOCATION not set. Enter Azure region [{0}]" -f $default)
    if ([string]::IsNullOrWhiteSpace($input)) { $input = $default }
    Write-Host -ForegroundColor Cyan ("Setting AZURE_LOCATION = {0}" -f $input)
    & azd env set AZURE_LOCATION $input | Out-Null
} else {
    Write-Host -ForegroundColor DarkGray ("AZURE_LOCATION already set: {0}" -f $env['AZURE_LOCATION'])
}
