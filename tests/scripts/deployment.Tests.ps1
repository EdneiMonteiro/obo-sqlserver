$ErrorActionPreference = 'Stop'
$global:OboDeploymentTest = @{
    Calls = [Collections.Generic.List[object]]::new()
    Objects = [Collections.Generic.List[object]]::new()
    FailBootstrap = $false
    PrivateProbe = $false
    PublicStorage = $false
    ValidationIdentities = @()
    IdentityResources = @()
    RoleResources = @()
}
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function az {
    $global:OboDeploymentTest.Calls.Add(@($args))
    $global:LASTEXITCODE = 0
    switch ("$($args[0]) $($args[1])") {
        'rest --method' { return '{"tenantId":"11111111-1111-1111-1111-111111111111","state":"Enabled"}' }
        'account set' { return }
        'aks get-credentials' { return }
        'account get-access-token' { return 'synthetic-sql-bootstrap-token' }
        'group show' { return '{"location":"brazilsouth","tags":{"workload":"obo-sqlserver"}}' }
        'deployment group' {
            if ($args[2] -eq 'what-if') { return }
            if ($args[2] -eq 'create') {
                return (@{ properties = @{ outputs = @{ identities = @{ value = $global:OboDeploymentTest.ValidationIdentities } } } } | ConvertTo-Json -Depth 15)
            }
            throw 'Unexpected deployment operation.'
        }
        'identity list' { return (ConvertTo-Json -InputObject @($global:OboDeploymentTest.IdentityResources) -Depth 10) }
        'identity delete' { return }
        'role assignment' {
            if ($args[2] -eq 'list') { return (ConvertTo-Json -InputObject @($global:OboDeploymentTest.RoleResources) -Depth 10) }
            if ($args[2] -eq 'delete') { return }
            throw 'Unexpected role operation.'
        }
        'storage account' {
            if ($global:OboDeploymentTest.PublicStorage) { return '{"publicNetworkAccess":"Enabled","allowBlobPublicAccess":false}' }
            return '{"publicNetworkAccess":"Disabled","allowBlobPublicAccess":false}'
        }
        default { throw "Unexpected Azure call in deployment test: $($args[0]) $($args[1])." }
    }
}
function kubelogin {
    $global:OboDeploymentTest.Calls.Add(@('kubelogin') + $args)
    $global:LASTEXITCODE = 0
}
function kubectl {
    $global:LASTEXITCODE = 0
    $arguments = @($args | Select-Object -Skip 2)
    $global:OboDeploymentTest.Calls.Add(@('kubectl') + $arguments)
    if ($arguments[0] -eq 'apply' -and $arguments[-1] -eq '-') {
        $object = ($input | Out-String) | ConvertFrom-Json
        $global:OboDeploymentTest.Objects.Add($object)
        return
    }
    if ($arguments[0] -eq 'get' -and $arguments[1] -eq 'job') {
        $type = if ($global:OboDeploymentTest.FailBootstrap -and $arguments[2] -like 'obo-bootstrap-*') { 'Failed' } else { 'Complete' }
        return "{`"status`":{`"conditions`":[{`"type`":`"$type`",`"status`":`"True`"}]}}"
    }
    if ($arguments[0] -eq 'get' -and $arguments[1] -eq 'secret') { return }
    if ($arguments[0] -in @('get','annotate','apply','logs','delete','rollout','create')) { return }
    throw 'Unexpected kubectl call in deployment test.'
}
function Invoke-RestMethod {
    param([string] $Uri)
    if ($Uri.EndsWith('/healthz')) { return @{ status = 'ok' } }
    if ($Uri.EndsWith('/bff/session')) { return @{ authenticated = $false } }
    throw 'Unexpected HTTP call in deployment test.'
}
function Invoke-WebRequest {
    param([string] $Uri, [switch] $SkipHttpErrorCheck)
    if ($Uri -like '*blob.core.windows.net*') {
        if ($global:OboDeploymentTest.PrivateProbe) {
            return @{ StatusCode = 409; Content = ([char]0xFEFF + '<Error><Code>PublicAccessNotPermitted</Code></Error>') }
        }
        return @{ StatusCode = 403; Content = '' }
    }
    if ($Uri -like '*/api/documents/*') { return @{ StatusCode = 401; Content = '' } }
    return @{ StatusCode = 200; Content = '<title>Documentos protegidos</title>' }
}

$directory = Join-Path ([IO.Path]::GetTempPath()) "obo-deployment-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $directory | Out-Null
$statePath = Join-Path $directory 'deployment.local.json'
$subscription = '22222222-2222-2222-2222-222222222222'
$tenant = '11111111-1111-1111-1111-111111111111'
$state = @{
    subscriptionId = $subscription; tenantId = $tenant; resourceGroup = 'rg-example'
    infrastructureReady = $true; tag = 'app-existing'; operationsTag = 'operations-existing'
    sqlAdminObjectId = [guid]::NewGuid().ToString()
    applicationUsers = @(@{ objectId = [guid]::NewGuid().ToString(); canSend = $true; canRead = $true })
    istioRevision = 'asm-1-30'; api = @{ appId = [guid]::NewGuid().ToString() }; bff = @{ appId = [guid]::NewGuid().ToString() }
    outputs = @{
        clusterName = @{ value = 'aks-example' }; registryHost = @{ value = 'example.azurecr.io' }
        publicIpName = @{ value = 'pip-example' }; publicHost = @{ value = 'example.test' }
        sqlFqdn = @{ value = 'example.database.windows.net' }; databaseName = @{ value = 'documents' }
        blobContainerUrl = @{ value = 'https://example.blob.core.windows.net/spa' }; storageAccount = @{ value = 'example' }
        keyVaultKeyUrl = @{ value = 'https://example.vault.azure.net/keys/cmk-documents' }
        operationsClientId = @{ value = [guid]::NewGuid().ToString() }
        workloadName = @{ value = 'obosql' }; keyVaultName = @{ value = 'kv-example' }
    }
}
$validationPath = Join-Path $directory 'validation.local.json'
$validation = @{
    subscriptionId = $subscription; tenantId = $tenant; resourceGroup = 'rg-example'; ready = $true
    clusterName = 'aks-example'; sqlFqdn = 'example.database.windows.net'; databaseName = 'documents'
    identities = @('sender','reader','admin-with-key','admin-without-key') | ForEach-Object {
        @{ actor = $_; clientId = [guid]::NewGuid().ToString(); objectId = [guid]::NewGuid().ToString() }
    }
}
$validationScope = "/subscriptions/$subscription/resourceGroups/rg-example/providers/Microsoft.KeyVault/vaults/kv-example"
foreach ($identity in $validation.identities) {
    $identity.resourceId = "/subscriptions/$subscription/resourceGroups/rg-example/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obosql-test-$($identity.actor)"
    $identity.cryptoRoleId = if ($identity.actor -eq 'admin-without-key') { '' } else { "$validationScope/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid())" }
}
$global:OboDeploymentTest.ValidationIdentities = $validation.identities
$global:OboDeploymentTest.IdentityResources = @($validation.identities | ForEach-Object {
    @{ id = $_.resourceId; clientId = $_.clientId; principalId = $_.objectId; tags = @{ purpose = 'optional-validation' } }
})
$global:OboDeploymentTest.RoleResources = @($validation.identities | Where-Object cryptoRoleId | ForEach-Object {
    @{ id = $_.cryptoRoleId; principalId = $_.objectId; scope = $validationScope
       roleDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/12338af0-0e69-4776-bea7-57ae8d297424" }
})
$state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8
try {
    & "$PSScriptRoot\..\..\scripts\deploy-aks.ps1" -SubscriptionId $subscription -TenantId $tenant `
        -ResourceGroupName 'rg-example' -OutputDirectory $directory -SkipInfrastructure -SkipImageBuild *> $null
    $login = @($global:OboDeploymentTest.Calls | Where-Object { $_[0] -eq 'kubelogin' })
    Assert ($login.Count -eq 1 -and $login[0] -contains 'azurecli') 'Direct deploy must authenticate kubectl with Azure CLI.'
    $secret = @($global:OboDeploymentTest.Objects | Where-Object { $_.kind -eq 'Secret' -and $_.metadata.name -eq 'bootstrap-sql' })
    Assert ($secret.Count -eq 1 -and $secret[0].stringData.'access-token' -eq 'synthetic-sql-bootstrap-token') 'Bootstrap token was not passed on stdin.'
    $tlsSecret = @($global:OboDeploymentTest.Objects | Where-Object { $_.kind -eq 'Secret' -and $_.metadata.name -eq 'obo-tls' })
    Assert ($tlsSecret.Count -eq 1 -and $tlsSecret[0].type -eq 'kubernetes.io/tls') 'Ingress placeholder must use the immutable TLS Secret type.'
    Assert (-not ($global:OboDeploymentTest.Calls | Where-Object { $_ -contains 'synthetic-sql-bootstrap-token' })) 'Token leaked into native arguments.'
    $job = @($global:OboDeploymentTest.Objects | Where-Object kind -eq Job)
    Assert ($job.Count -eq 1 -and $job[0].spec.template.spec.containers[0].image -eq 'example.azurecr.io/obo-operations:operations-existing') 'Direct deployment lost the published operations tag.'
    $bootstrapEnvironment = $job[0].spec.template.spec.containers[0].env
    Assert (-not ($bootstrapEnvironment | Where-Object name -like 'TEST_*')) 'Functional bootstrap must not receive test identities.'
    Assert (@($global:OboDeploymentTest.Objects | Where-Object { $_.kind -eq 'ServiceAccount' -and $_.metadata.name -like 'test-*' }).Count -eq 0) 'Functional deploy created validation ServiceAccounts.'
    Assert (@($global:OboDeploymentTest.Calls | Where-Object { $_[0] -eq 'kubectl' -and $_[1] -eq 'delete' -and $_[3] -eq 'bootstrap-sql' }).Count -eq 1) 'Bootstrap secret not removed on success.'
    Assert ((Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).tag -eq 'app-existing') 'SkipImageBuild changed the existing app tag.'

    $global:OboDeploymentTest.Calls.Clear()
    $global:OboDeploymentTest.FailBootstrap = $true
    $failed = $false
    try {
        & "$PSScriptRoot\..\..\scripts\deploy-aks.ps1" -SubscriptionId $subscription -TenantId $tenant `
            -ResourceGroupName 'rg-example' -OutputDirectory $directory -SkipInfrastructure -SkipImageBuild *> $null
    } catch { $failed = $_.Exception.Message -match 'Job .* failed' }
    Assert $failed 'Failed bootstrap must fail deployment.'
    Assert (@($global:OboDeploymentTest.Calls | Where-Object { $_[0] -eq 'kubectl' -and $_[1] -eq 'delete' -and $_[3] -eq 'bootstrap-sql' }).Count -eq 1) 'Bootstrap secret not removed on failure.'
    $global:OboDeploymentTest.FailBootstrap = $false
    $global:OboDeploymentTest.Objects.Clear()
    & "$PSScriptRoot\..\..\scripts\test-aks.ps1" -SubscriptionId $subscription -StatePath $statePath *> $null
    Assert ($global:OboDeploymentTest.Objects.Count -eq 0) 'Default validation must not deploy test resources.'
    $failed = $false
    try { & "$PSScriptRoot\..\..\scripts\test-aks.ps1" -SubscriptionId $subscription -StatePath $statePath -IncludeSegregation *> $null }
    catch { $failed = $_.Exception.Message -match 'setup-validation.ps1' }
    Assert $failed 'Segregation without explicit setup must fail.'
    $global:OboDeploymentTest.Objects.Clear()
    & "$PSScriptRoot\..\..\scripts\setup-validation.ps1" -SubscriptionId $subscription -StatePath $statePath *> $null
    $configured = Get-Content -LiteralPath $validationPath -Raw | ConvertFrom-Json
    Assert ($configured.ready -and @($configured.identities).Count -eq 4) 'Optional validation setup did not finish.'
    Assert (@($global:OboDeploymentTest.Objects | Where-Object { $_.kind -eq 'ServiceAccount' -and $_.metadata.name -like 'test-*' }).Count -eq 4) 'Optional setup must create four test accounts.'
    $setupJob = @($global:OboDeploymentTest.Objects | Where-Object kind -eq Job)
    Assert ($setupJob.Count -eq 1 -and $setupJob[0].spec.template.spec.containers[0].args[0] -eq 'setup-validation') 'Validation grants were not isolated in their own operation.'
    Assert (-not (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).outputs.PSObject.Properties['testIdentities']) 'Validation polluted the functional deployment state.'

    foreach ($privateProbe in @($false, $true)) {
        $global:OboDeploymentTest.PrivateProbe = $privateProbe
        $global:OboDeploymentTest.Objects.Clear()
        & "$PSScriptRoot\..\..\scripts\test-aks.ps1" -SubscriptionId $subscription -StatePath $statePath -FromPrivateNetwork:$privateProbe -IncludeSegregation *> $null
        Assert (@($global:OboDeploymentTest.Objects | Where-Object kind -eq Job).Count -eq 4) 'Validation must run all four actors.'
    }
    $global:OboDeploymentTest.PublicStorage = $true
    $failed = $false
    try { & "$PSScriptRoot\..\..\scripts\test-aks.ps1" -SubscriptionId $subscription -StatePath $statePath *> $null }
    catch { $failed = $_.Exception.Message -eq 'Storage public access is not disabled.' }
    Assert $failed 'Validation must reject a publicly enabled Storage account.'
    $global:OboDeploymentTest.Calls.Clear()
    & "$PSScriptRoot\..\..\scripts\remove-validation.ps1" -SubscriptionId $subscription -StatePath $statePath -WhatIf *> $null
    Assert ($global:OboDeploymentTest.Calls.Count -eq 0) 'Validation removal WhatIf contacted Azure.'
    $global:OboDeploymentTest.IdentityResources[0].tags.purpose = 'different-owner'
    $failed = $false
    try { & "$PSScriptRoot\..\..\scripts\remove-validation.ps1" -SubscriptionId $subscription -StatePath $statePath -Confirm:$false *> $null }
    catch { $failed = $_.Exception.Message -eq 'Identity ownership differs from validation state.' }
    Assert $failed 'Teardown accepted an identity that no longer belongs to validation.'
    Assert (@($global:OboDeploymentTest.Calls | Where-Object { $_ -contains 'delete' }).Count -eq 0) 'Teardown mutated resources before ownership checks.'
    $global:OboDeploymentTest.IdentityResources[0].tags.purpose = 'optional-validation'
    $global:OboDeploymentTest.Calls.Clear()
    $global:OboDeploymentTest.Objects.Clear()
    & "$PSScriptRoot\..\..\scripts\remove-validation.ps1" -SubscriptionId $subscription -StatePath $statePath -Confirm:$false *> $null
    Assert (-not (Test-Path -LiteralPath $validationPath)) 'Validation removal did not clear its state.'
    Assert (@($global:OboDeploymentTest.Calls | Where-Object { $_[0] -eq 'identity' -and $_[1] -eq 'delete' }).Count -eq 4) 'Validation removal must remove exactly its four identities.'
    Assert (@($global:OboDeploymentTest.Calls | Where-Object { $_[0] -eq 'role' -and $_[2] -eq 'delete' }).Count -eq 3) 'Validation removal must remove exactly its three crypto grants.'
    Assert (@($global:OboDeploymentTest.Calls | Where-Object { $_[0] -eq 'group' -and $_[1] -eq 'delete' }).Count -eq 0) 'Optional teardown tried to delete the application RG.'
    $removeJob = @($global:OboDeploymentTest.Objects | Where-Object kind -eq Job)
    Assert ($removeJob.Count -eq 1 -and $removeJob[0].spec.template.spec.containers[0].args[0] -eq 'remove-validation') 'SQL validation teardown used the wrong operation.'
    $configured | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $validationPath -Encoding utf8
    $global:OboDeploymentTest.IdentityResources = @($global:OboDeploymentTest.IdentityResources | Select-Object -Skip 1)
    $global:OboDeploymentTest.RoleResources = @($global:OboDeploymentTest.RoleResources | Select-Object -Skip 1)
    $global:OboDeploymentTest.Calls.Clear()
    & "$PSScriptRoot\..\..\scripts\remove-validation.ps1" -SubscriptionId $subscription -StatePath $statePath -Confirm:$false *> $null
    Assert (@($global:OboDeploymentTest.Calls | Where-Object { $_[0] -eq 'identity' -and $_[1] -eq 'delete' }).Count -eq 3) 'Partial teardown retry must delete only remaining identities.'
    Assert (@($global:OboDeploymentTest.Calls | Where-Object { $_[0] -eq 'role' -and $_[2] -eq 'delete' }).Count -eq 2) 'Partial teardown retry must delete only remaining grants.'
    Write-Host 'PASS: direct AKS deploy, bootstrap cleanup, private Storage checks and four-actor validation; Azure mocked.'
} finally {
    foreach ($name in @('deployment.local.json','validation.local.json','validation.parameters.local.json','apps.local.yaml','ingress.local.yaml')) {
        $file = Join-Path $directory $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    Remove-Item -LiteralPath $directory
    Remove-Variable -Name OboDeploymentTest -Scope Global
    $global:LASTEXITCODE = 0
}
