param(
    [Parameter(Mandatory = $true)]
    [string] $SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string] $Location = "brazilsouth",

    [Parameter(Mandatory = $false)]
    [string] $ResourceGroupName = "rg-obo-sql-poc-brazilsouth-001",

    [Parameter(Mandatory = $false)]
    [string] $ParametersFile = ".\infra\bicep\main.parameters.local.json"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ParametersFile)) {
    throw "Parameters file not found: $ParametersFile. Copy infra\bicep\main.parameters.json.example first."
}

az account set --subscription $SubscriptionId
az group create --name $ResourceGroupName --location $Location --only-show-errors | Out-Host

az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file ".\infra\bicep\main.bicep" `
    --parameters "@$ParametersFile" `
    --only-show-errors | Out-Host

