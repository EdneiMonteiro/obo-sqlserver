<#
.SYNOPSIS
Remove only optional validation identities and SQL users, preserving the application.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
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
$validationPath = Join-Path $script:OutputDirectory 'validation.local.json'
$validation = Get-Content -LiteralPath $validationPath -Raw | ConvertFrom-Json
if ($state.subscriptionId -ne $script:SubscriptionId -or $validation.subscriptionId -ne $state.subscriptionId -or
    $validation.tenantId -ne $state.tenantId -or $validation.resourceGroup -ne $state.resourceGroup -or
    $validation.clusterName -ne $state.outputs.clusterName.value -or
    $validation.sqlFqdn -ne $state.outputs.sqlFqdn.value -or $validation.databaseName -ne $state.outputs.databaseName.value) {
    throw 'Validation state/target mismatch.'
}
$identities = @(Get-ValidationIdentities $validation)
$prefix = "/subscriptions/$SubscriptionId/resourceGroups/$($state.resourceGroup)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/"
foreach ($identity in $identities) {
    $expected = $prefix + "id-$($state.outputs.workloadName.value)-test-$($identity.actor)"
    if ($identity.resourceId -ne $expected) { throw 'Unexpected validation resource ID; refusing deletion.' }
}
if (-not $PSCmdlet.ShouldProcess($state.resourceGroup, 'Remove optional validation SQL users, identities, role assignments and Jobs')) { return }
$subscription = Invoke-Az rest --method GET --url "https://management.azure.com/subscriptions/$SubscriptionId`?api-version=2022-12-01" -o json | ConvertFrom-Json
if ($subscription.tenantId -ne $state.tenantId) { throw 'Tenant mismatch.' }
$resources = @(Invoke-Az identity list -g $state.resourceGroup -o json | ConvertFrom-Json)
$expectedScope = "/subscriptions/$SubscriptionId/resourceGroups/$($state.resourceGroup)/providers/Microsoft.KeyVault/vaults/$($state.outputs.keyVaultName.value)"
$roles = @(Invoke-Az role assignment list --scope $expectedScope -o json | ConvertFrom-Json)
$deleteIdentities = @()
$deleteRoles = @()
foreach ($identity in $identities) {
    $resource = @($resources | Where-Object id -eq $identity.resourceId)
    if ($resource.Count -gt 1) { throw 'Ambiguous validation identity.' }
    if ($resource.Count -eq 1 -and ($resource[0].clientId -ne $identity.clientId -or $resource[0].principalId -ne $identity.objectId -or
        $resource[0].tags.purpose -ne 'optional-validation')) { throw 'Identity ownership differs from validation state.' }
    if ($resource.Count -eq 1) { $deleteIdentities += $identity.resourceId }
    if ($identity.cryptoRoleId) {
        if (-not $identity.cryptoRoleId.StartsWith("$expectedScope/providers/Microsoft.Authorization/roleAssignments/", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Validation role assignment belongs to another scope.'
        }
        $role = @($roles | Where-Object id -eq $identity.cryptoRoleId)
        if ($role.Count -gt 1) { throw 'Ambiguous validation role assignment.' }
        if ($role.Count -eq 1 -and ($role[0].principalId -ne $identity.objectId -or $role[0].scope -ne $expectedScope -or
            $role[0].roleDefinitionId -notlike '*/12338af0-0e69-4776-bea7-57ae8d297424')) { throw 'Unexpected validation role assignment.' }
        if ($role.Count -eq 1) { $deleteRoles += $identity.cryptoRoleId }
    }
}
Initialize-Kubernetes $state
$validation.ready = $false
$validation | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $validationPath -Encoding utf8
Start-AdministrativeOperation -Mode 'remove-validation' -State $state -Validation $validation
Invoke-Kubectl delete jobs -n obo-operations -l app.kubernetes.io/component=validation --ignore-not-found | Out-Null
foreach ($identity in $identities) {
    Invoke-Kubectl delete serviceaccount "test-$($identity.actor)" -n obo-operations --ignore-not-found | Out-Null
}
foreach ($roleId in $deleteRoles) { Invoke-Az role assignment delete --ids $roleId -o none }
foreach ($identityId in $deleteIdentities) { Invoke-Az identity delete --ids $identityId }
Remove-Item -LiteralPath $validationPath
Write-Host 'Optional validation identities and SQL access removed. Application resources were preserved.'
