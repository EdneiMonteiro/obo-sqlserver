param(
    [Parameter(Mandatory = $true)]
    [string] $TenantId,

    [Parameter(Mandatory = $false)]
    [string] $ForecastsPath = ".\scripts\forecasts.example.json",

    [Parameter(Mandatory = $false)]
    [decimal] $BrlToUsdRate = 0.185,

    [Parameter(Mandatory = $false)]
    [string[]] $CandidateLocations = @("brazilsouth", "eastus", "eastus2")
)

$ErrorActionPreference = "Stop"

function Convert-ToUsd {
    param(
        [decimal] $Amount,
        [string] $Currency
    )

    switch ($Currency.ToUpperInvariant()) {
        "USD" { return $Amount }
        "BRL" { return [decimal]::Round($Amount * $BrlToUsdRate, 2) }
        default { throw "Unsupported currency '$Currency'. Add a conversion rule before selecting a subscription." }
    }
}

Write-Host "Checking Azure login for tenant $TenantId..."
$accounts = az account list --all -o json | ConvertFrom-Json
$tenantSubscriptions = $accounts | Where-Object { $_.tenantId -eq $TenantId -and $_.state -eq "Enabled" }

if (-not $tenantSubscriptions) {
    throw "No enabled subscriptions found for tenant $TenantId. Run: az login --tenant $TenantId"
}

Write-Host ""
Write-Host "Enabled subscriptions in tenant:"
$tenantSubscriptions | Select-Object name,id,tenantId,state,isDefault | Format-Table -AutoSize

if (Test-Path -LiteralPath $ForecastsPath) {
    Write-Host ""
    Write-Host "Forecast headroom using $ForecastsPath:"
    $forecasts = Get-Content -Raw -LiteralPath $ForecastsPath | ConvertFrom-Json
    $ranked = foreach ($item in $forecasts) {
        if ($item.subscriptionId -like "<*") {
            continue
        }

        $forecastUsd = Convert-ToUsd -Amount ([decimal]$item.forecast) -Currency ([string]$item.currency)
        [pscustomobject]@{
            Name = $item.name
            SubscriptionId = $item.subscriptionId
            Currency = $item.currency
            ForecastOriginal = $item.forecast
            ForecastUsd = $forecastUsd
            LimitUsd = $item.limitUsd
            HeadroomUsd = [decimal]$item.limitUsd - $forecastUsd
        }
    }

    if ($ranked) {
        $ranked | Sort-Object HeadroomUsd -Descending | Format-Table -AutoSize
        $winner = $ranked | Sort-Object HeadroomUsd -Descending | Select-Object -First 1
        Write-Host "Recommended subscription: $($winner.SubscriptionId) ($($winner.Name)), headroom USD $($winner.HeadroomUsd)"
    }
    else {
        Write-Warning "Forecast file still contains placeholder subscription IDs. Map names to IDs before automatic selection."
    }
}

$providers = @(
    "Microsoft.App",
    "Microsoft.Sql",
    "Microsoft.KeyVault",
    "Microsoft.OperationalInsights",
    "Microsoft.ManagedIdentity"
)

foreach ($subscription in $tenantSubscriptions) {
    Write-Host ""
    Write-Host "Validating providers for subscription $($subscription.id)..."
    az account set --subscription $subscription.id

    foreach ($provider in $providers) {
        $state = az provider show --namespace $provider --query "registrationState" -o tsv
        Write-Host "$provider => $state"
    }

    Write-Host "Candidate locations:"
    foreach ($location in $CandidateLocations) {
        Write-Host " - $location"
    }
}

