param(
    [Parameter(Mandatory = $true)]
    [string] $SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string] $ResourceGroupName = "rg-obo-sql-poc-brazilsouth-001"
)

$ErrorActionPreference = "Stop"

az account set --subscription $SubscriptionId
az group delete --name $ResourceGroupName --yes --no-wait
Write-Host "Delete requested for $ResourceGroupName."

