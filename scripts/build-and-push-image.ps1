param(
    [Parameter(Mandatory = $true)] [string] $SubscriptionId,
    [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
    [Parameter(Mandatory = $true)] [string] $AcrName,
    [Parameter(Mandatory = $false)] [string] $Tag = "1.0.0",
    [Parameter(Mandatory = $false)] [string] $ImageName = "obo-sqlserver-api"
)

$ErrorActionPreference = "Stop"

az account set --subscription $SubscriptionId

if (-not (az acr show -g $ResourceGroupName -n $AcrName --query name -o tsv --only-show-errors 2>$null)) {
    Write-Host "Creating ACR $AcrName (Basic)..."
    az acr create -g $ResourceGroupName -n $AcrName --sku Basic --admin-enabled false --only-show-errors -o none
} else {
    Write-Host "ACR $AcrName already exists."
}

$loginServer = az acr show -g $ResourceGroupName -n $AcrName --query loginServer -o tsv
Write-Host "Building $loginServer/${ImageName}:$Tag via az acr build..."
az acr build -r $AcrName -t "${ImageName}:$Tag" -f Dockerfile . --only-show-errors -o none

Write-Host "Image pushed: $loginServer/${ImageName}:$Tag"
Write-Output @{ loginServer = $loginServer; image = "$loginServer/${ImageName}:$Tag" } | ConvertTo-Json -Compress
