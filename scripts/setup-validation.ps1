<#
.SYNOPSIS
Opt-in SQL/Key Vault validation resources. Not called by the functional deployment.
Creates four workload identities and test SQL users, including two db_owner controls.
#>
param(
    [Parameter(Mandatory)] [guid] $SubscriptionId,
    [Parameter(Mandatory)] [string] $StatePath
)
. "$PSScriptRoot\aks-common.ps1"
$script:SubscriptionId = $SubscriptionId.ToString()
$StatePath = [IO.Path]::GetFullPath($StatePath)
$script:OutputDirectory = Split-Path $StatePath -Parent
$script:KubeConfig = Join-Path $script:OutputDirectory 'kubeconfig.local'
$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
if ($state.subscriptionId -ne $script:SubscriptionId -or -not $state.infrastructureReady) { throw 'Deployment state/target mismatch.' }
if (-not $state.outputs.PSObject.Properties['workloadName'] -or -not $state.PSObject.Properties['applicationUsers']) {
    throw 'Functional state is outdated. Re-run the infrastructure step with explicit application participants.'
}
if (-not $state.PSObject.Properties['operationsTag'] -or [string]::IsNullOrWhiteSpace($state.operationsTag)) {
    throw 'Build/publish the functional deployment before configuring optional validation.'
}
$subscription = Invoke-Az rest --method GET --url "https://management.azure.com/subscriptions/$SubscriptionId`?api-version=2022-12-01" -o json | ConvertFrom-Json
if ($subscription.tenantId -ne $state.tenantId) { throw 'Tenant mismatch.' }
$group = Invoke-Az group show -n $state.resourceGroup -o json | ConvertFrom-Json
if ($group.tags.workload -ne 'obo-sqlserver') { throw 'Resource group is not owned by this example.' }
$parameters = @{
    location = @{ value = $group.location }; workloadName = @{ value = $state.outputs.workloadName.value }
    clusterName = @{ value = $state.outputs.clusterName.value }; keyVaultName = @{ value = $state.outputs.keyVaultName.value }
}
$path = Join-Path $script:OutputDirectory 'validation.parameters.local.json'
@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
    ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
$template = Join-Path $PSScriptRoot '..\infra\bicep\validation.bicep'
Invoke-Az deployment group what-if -g $state.resourceGroup --template-file $template --parameters "@$path" --result-format ResourceIdOnly
$deployment = Invoke-Az deployment group create -g $state.resourceGroup -n obo-validation --template-file $template --parameters "@$path" -o json | ConvertFrom-Json
$validation = @{
    subscriptionId = $state.subscriptionId; tenantId = $state.tenantId; resourceGroup = $state.resourceGroup
    clusterName = $state.outputs.clusterName.value; sqlFqdn = $state.outputs.sqlFqdn.value; databaseName = $state.outputs.databaseName.value
    identities = @($deployment.properties.outputs.identities.value); ready = $false
}
$validationPath = Join-Path $script:OutputDirectory 'validation.local.json'
$validation | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $validationPath -Encoding utf8
$null = Get-ValidationIdentities $validation
Initialize-Kubernetes $state
Apply-Object @{ apiVersion = 'v1'; kind = 'Namespace'; metadata = @{ name = 'obo-operations' } }
foreach ($identity in $validation.identities) {
    Apply-Object @{
        apiVersion = 'v1'; kind = 'ServiceAccount'
        metadata = @{
            name = "test-$($identity.actor)"; namespace = 'obo-operations'
            annotations = @{ 'azure.workload.identity/client-id' = $identity.clientId; 'azure.workload.identity/tenant-id' = $state.tenantId }
        }
    }
}
Start-AdministrativeOperation -Mode 'setup-validation' -State $state -Validation $validation
$validation.ready = $true
$validation | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $validationPath -Encoding utf8
Write-Host 'Optional validation configured. Run test-aks.ps1 -IncludeSegregation explicitly.'
