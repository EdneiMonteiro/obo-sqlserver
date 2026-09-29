<#
.SYNOPSIS
Legacy ACA infrastructure deployment. For the primary architecture use deploy-aks.ps1.
.LINK
../docs/legacy/aca.md
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string] $Location = "brazilsouth",

    [Parameter(Mandatory = $false)]
    [string] $ResourceGroupName = "rg-obo-sql-poc-brs-001",

    [Parameter(Mandatory = $false)]
    [string] $ParametersFile = ".\infra\bicep\main.parameters.local.json"
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\azure-common.ps1"

if (-not (Test-Path -LiteralPath $ParametersFile)) {
    throw "Parameters file not found: $ParametersFile. Copy infra\bicep\main.parameters.json.example first."
}

Initialize-AzureContext -SubscriptionId $SubscriptionId
Invoke-Az group create --name $ResourceGroupName --location $Location | Out-Host

Invoke-Az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file ".\infra\bicep\main.bicep" `
    --parameters "@$ParametersFile" | Out-Host
