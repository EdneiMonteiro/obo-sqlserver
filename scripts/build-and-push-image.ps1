<#
.SYNOPSIS
Legacy ACA single-API image build. The AKS publisher builds API, BFF and operations images.
.LINK
../docs/legacy/aca.md
#>
param(
    [Parameter(Mandatory = $true)] [string] $SubscriptionId,
    [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
    [Parameter(Mandatory = $true)] [string] $AcrName,
    [Parameter(Mandatory = $false)] [string] $Tag = "1.0.0",
    [Parameter(Mandatory = $false)] [string] $ImageName = "obo-sqlserver-api"
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\azure-common.ps1"

Initialize-AzureContext -SubscriptionId $SubscriptionId

$registries = @(Invoke-Az acr list -g $ResourceGroupName -o json | ConvertFrom-Json)
if (-not ($registries | Where-Object name -eq $AcrName)) {
    Write-Host "Creating ACR $AcrName (Basic)..."
    Invoke-Az acr create -g $ResourceGroupName -n $AcrName --sku Basic --admin-enabled false -o none
} else {
    Write-Host "ACR $AcrName already exists."
}

$loginServer = Invoke-Az acr show -g $ResourceGroupName -n $AcrName --query loginServer -o tsv
Write-Host "Building $loginServer/${ImageName}:$Tag via az acr build..."
Invoke-Az acr build -r $AcrName -t "${ImageName}:$Tag" -f Dockerfile . -o none

Write-Host "Image pushed: $loginServer/${ImageName}:$Tag"
Write-Output @{ loginServer = $loginServer; image = "$loginServer/${ImageName}:$Tag" } | ConvertTo-Json -Compress
