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
az account set --subscription $SubscriptionId

$identityId       = az identity show -g $ResourceGroupName -n $ManagedIdentityName --query id          -o tsv
$identityPrincipal = az identity show -g $ResourceGroupName -n $ManagedIdentityName --query principalId -o tsv
$acrResourceId    = az acr show       -g $ResourceGroupName -n $AcrName             --query id          -o tsv

Write-Host "Granting AcrPull on $AcrName to $ManagedIdentityName ..."
az role assignment create `
    --assignee-object-id $identityPrincipal `
    --assignee-principal-type ServicePrincipal `
    --role AcrPull `
    --scope $acrResourceId `
    --only-show-errors -o none 2>$null

$loginServer = az acr show -g $ResourceGroupName -n $AcrName --query loginServer -o tsv

Write-Host "Configuring ACR registry on the Container App with user-assigned identity..."
az containerapp registry set -g $ResourceGroupName -n $ContainerAppName --server $loginServer --identity $identityId --only-show-errors -o none

if (-not (Test-Path -LiteralPath $ClientSecretFile)) { throw "Client secret file not found: $ClientSecretFile" }
$clientSecret = (Get-Content -LiteralPath $ClientSecretFile -Raw).Trim()

Write-Host "Setting Container App secret 'azuread-client-secret'..."
az containerapp secret set -g $ResourceGroupName -n $ContainerAppName --secrets "azuread-client-secret=$clientSecret" --only-show-errors -o none

Write-Host "Updating image and environment variables..."
$envVars = @(
    "AzureAd__TenantId=$TenantId",
    "AzureAd__ClientId=$ApiClientId",
    "AzureAd__Audience=$ApiClientId",
    "AzureAd__ClientSecret=secretref:azuread-client-secret",
    "Sql__MaxDocumentBytes=10485760"
)
az containerapp update -g $ResourceGroupName -n $ContainerAppName --image $Image --set-env-vars $envVars --only-show-errors -o none

$fqdn = az containerapp show -g $ResourceGroupName -n $ContainerAppName --query properties.configuration.ingress.fqdn -o tsv
Write-Host "Container App updated. URL: https://$fqdn"
