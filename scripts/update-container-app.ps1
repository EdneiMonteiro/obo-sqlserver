<#
.SYNOPSIS
Legacy ACA image, registry and client-secret configuration; not used by AKS.
.LINK
../docs/legacy/aca.md
#>
param(
    [Parameter(Mandatory = $true)] [string] $SubscriptionId,
    [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
    [Parameter(Mandatory = $true)] [string] $ContainerAppName,
    [Parameter(Mandatory = $true)] [string] $ManagedIdentityName,
    [Parameter(Mandatory = $true)] [string] $AcrName,
    [Parameter(Mandatory = $true)] [string] $Image,
    [Parameter(Mandatory = $true)] [string] $TenantId,
    [Parameter(Mandatory = $true)] [string] $ApiClientId,
    [Parameter(Mandatory = $true)] [string] $ClientSecretFile
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\azure-common.ps1"
Initialize-AzureContext -SubscriptionId $SubscriptionId -TenantId $TenantId

$identityId       = Invoke-Az identity show -g $ResourceGroupName -n $ManagedIdentityName --query id          -o tsv
$identityPrincipal = Invoke-Az identity show -g $ResourceGroupName -n $ManagedIdentityName --query principalId -o tsv
$acrResourceId    = Invoke-Az acr show       -g $ResourceGroupName -n $AcrName             --query id          -o tsv

Write-Host "Granting AcrPull on $AcrName to $ManagedIdentityName ..."
Ensure-AzureRoleAssignment -ObjectId $identityPrincipal -Role AcrPull -Scope $acrResourceId

$loginServer = Invoke-Az acr show -g $ResourceGroupName -n $AcrName --query loginServer -o tsv

Write-Host "Configuring ACR registry on the Container App with user-assigned identity..."
Invoke-Az containerapp registry set -g $ResourceGroupName -n $ContainerAppName --server $loginServer --identity $identityId -o none

if (-not (Test-Path -LiteralPath $ClientSecretFile)) { throw "Client secret file not found: $ClientSecretFile" }
$clientSecret = (Get-Content -LiteralPath $ClientSecretFile -Raw).Trim()

Write-Host "Setting Container App secret 'azuread-client-secret'..."
Invoke-Az containerapp secret set -g $ResourceGroupName -n $ContainerAppName --secrets "azuread-client-secret=$clientSecret" -o none

Write-Host "Updating image and environment variables..."
$envVars = @(
    "AzureAd__TenantId=$TenantId",
    "AzureAd__ClientId=$ApiClientId",
    "AzureAd__Audience=$ApiClientId",
    "AzureAd__ClientSecret=secretref:azuread-client-secret",
    "Sql__MaxDocumentBytes=10485760"
)
Invoke-Az containerapp update -g $ResourceGroupName -n $ContainerAppName --image $Image --set-env-vars $envVars -o none

$fqdn = Invoke-Az containerapp show -g $ResourceGroupName -n $ContainerAppName --query properties.configuration.ingress.fqdn -o tsv
Write-Host "Container App updated. URL: https://$fqdn"
