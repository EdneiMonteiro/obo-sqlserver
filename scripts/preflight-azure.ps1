<#
.SYNOPSIS
Read-only provider inventory for the primary AKS architecture or the legacy ACA path.
Region candidates do not establish quota or SKU availability.
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $TenantId,

    [ValidateSet('AKS', 'ACA')]
    [string] $Architecture = 'AKS',

    [Parameter(Mandatory = $false)]
    [string[]] $CandidateLocations = @("brazilsouth", "eastus", "eastus2")
)

$ErrorActionPreference = "Stop"

Write-Host "Checking Azure login for tenant $TenantId..."
$accountsJson = az account list --all -o json --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Failed to list subscriptions.' }
$accounts = $accountsJson | ConvertFrom-Json
$tenantSubscriptions = $accounts | Where-Object { $_.tenantId -eq $TenantId -and $_.state -eq "Enabled" }

if (-not $tenantSubscriptions) {
    throw "No enabled subscriptions found for tenant $TenantId. Run: az login --tenant $TenantId"
}

Write-Host ""
Write-Host "Enabled subscriptions (names are CLI cache values; confirm displayName through ARM):"
$tenantSubscriptions | Select-Object name,id,tenantId,state,isDefault | Format-Table -AutoSize

$providers = @(
    "Microsoft.Sql",
    "Microsoft.KeyVault",
    "Microsoft.ManagedIdentity",
    "Microsoft.ContainerRegistry"
)
if ($Architecture -eq 'AKS') {
    $providers += @('Microsoft.ContainerService', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.Compute')
} else {
    $providers += @('Microsoft.App', 'Microsoft.OperationalInsights')
}

foreach ($subscription in $tenantSubscriptions) {
    Write-Host ""
    Write-Host "Validating providers for subscription $($subscription.id)..."
    foreach ($provider in $providers) {
        $state = az provider show --subscription $subscription.id --namespace $provider --query "registrationState" -o tsv --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Failed to query provider $provider." }
        Write-Host "$provider => $state"
    }

    Write-Host "Candidate locations (quota/SKU/version availability still needs verification):"
    foreach ($location in $CandidateLocations) {
        Write-Host " - $location"
    }
}
