$ErrorActionPreference = 'Stop'
$subscription = '22222222-2222-2222-2222-222222222222'
$tenant = '11111111-1111-1111-1111-111111111111'
$principal = '55555555-5555-5555-5555-555555555555'
$global:OboAzureCliTest = @{
    Calls = [Collections.Generic.List[object]]::new()
    FailAt = ''; Subscription = $subscription; Tenant = $tenant
    RegistryExists = $true; RoleExists = $true; SqlCalls = 0
}
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Argument($Arguments, [string] $Name) {
    $index = [Array]::IndexOf($Arguments, $Name)
    if ($index -lt 0) { return '' }
    return $Arguments[$index + 1]
}
function az {
    $state = $global:OboAzureCliTest
    $state.Calls.Add(@($args))
    $global:LASTEXITCODE = 0
    $command = ($args | Select-Object -First 2) -join ' '
    $operation = ($args | Select-Object -First 3) -join ' '
    if ($state.FailAt -and ($command -eq $state.FailAt -or $operation -eq $state.FailAt)) {
        $global:LASTEXITCODE = 7
        return
    }
    switch ($command) {
        'account set' { $state.Subscription = Argument $args '--subscription'; return }
        'account show' {
            switch (Argument $args '--query') {
                'id' { return $state.Subscription }
                'tenantId' { return $state.Tenant }
                default { return (@{ id = $state.Subscription; tenantId = $state.Tenant; state = 'Enabled' } | ConvertTo-Json -Compress) }
            }
        }
        'account get-access-token' { return 'synthetic-token' }
        'group create' { return '{}' }
        'deployment group' { if ($args[2] -eq 'create') { return '{}' }; throw 'Unexpected deployment operation.' }
        'acr list' { if ($state.RegistryExists) { return '[{"name":"exampleacr"}]' }; return '[]' }
        'acr show' { if ((Argument $args '--query') -eq 'loginServer') { return 'example.azurecr.io' }; return '/subscriptions/example/resourceGroups/example/providers/Microsoft.ContainerRegistry/registries/exampleacr' }
        'acr create' { return }
        'acr build' { return }
        'identity show' { if ((Argument $args '--query') -eq 'principalId') { return '55555555-5555-5555-5555-555555555555' }; return '/subscriptions/example/resourceGroups/example/providers/Microsoft.ManagedIdentity/userAssignedIdentities/example' }
        'keyvault show' { return '/subscriptions/example/resourceGroups/example/providers/Microsoft.KeyVault/vaults/example' }
        'role assignment' {
            if ($args[2] -eq 'list') {
                if ($state.RoleExists) { return '[{"principalId":"55555555-5555-5555-5555-555555555555"}]' }
                return '[]'
            }
            if ($args[2] -eq 'create') { return }
            throw 'Unexpected role operation.'
        }
        'containerapp registry' { return }
        'containerapp secret' { return }
        'containerapp update' { return }
        'containerapp show' { return 'example.test' }
        'ad app' {
            if ($args[2] -in @('list','create')) { return '{"appId":"44444444-4444-4444-4444-444444444444","id":"66666666-6666-6666-6666-666666666666"}' }
            if ($args[2] -eq 'credential') { return '{"password":"synthetic-secret"}' }
            if ($args[2] -in @('update','permission')) { return }
            throw 'Unexpected app operation.'
        }
        'ad sp' { if ($args[2] -eq 'show') { return '55555555-5555-5555-5555-555555555555' }; return '{"id":"55555555-5555-5555-5555-555555555555"}' }
        'ad signed-in-user' { return '{"id":"55555555-5555-5555-5555-555555555555"}' }
        'rest --method' { return }
        default { throw "Unexpected mock Azure call: $command." }
    }
}
function Import-Module { param([string] $Name, [switch] $Force) }
function Invoke-Sqlcmd { $global:OboAzureCliTest.SqlCalls++; throw 'SQL must not be reached in Azure CLI failure tests.' }
function Invoke-WebRequest { throw 'HTTP must not be reached in Azure CLI failure tests.' }

$directory = Join-Path ([IO.Path]::GetTempPath()) "obo-azure-cli-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $directory | Out-Null
$parameters = Join-Path $directory 'parameters.local.json'
$secretFile = Join-Path $directory 'secret.local.txt'
$secretsFile = Join-Path $directory 'identities.local.json'
'{}' | Set-Content -LiteralPath $parameters
'synthetic-secret' | Set-Content -LiteralPath $secretFile
$scripts = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts'))
$cases = @(
    @{ Name = 'deploy-infra'; Parameters = @{ SubscriptionId = $subscription; ResourceGroupName = 'rg-example'; ParametersFile = $parameters } },
    @{ Name = 'build-and-push-image'; Parameters = @{ SubscriptionId = $subscription; ResourceGroupName = 'rg-example'; AcrName = 'exampleacr' } },
    @{ Name = 'update-container-app'; Parameters = @{ SubscriptionId = $subscription; ResourceGroupName = 'rg-example'; ContainerAppName = 'example'; ManagedIdentityName = 'example'; AcrName = 'exampleacr'; Image = 'example.azurecr.io/api:test'; TenantId = $tenant; ApiClientId = $principal; ClientSecretFile = $secretFile } },
    @{ Name = 'setup-separation-of-duties'; Parameters = @{ SubscriptionId = $subscription; ResourceGroupName = 'rg-example'; SqlServerFqdn = 'example.database.windows.net'; DatabaseName = 'documents'; KeyVaultName = 'example'; TenantId = $tenant; SecretsOutputPath = $secretsFile } },
    @{ Name = 'create-app-registration'; Parameters = @{ TenantId = $tenant; SecretOutputPath = $secretFile } },
    @{ Name = 'setup-always-encrypted'; Parameters = @{ SqlServerFqdn = 'example.database.windows.net'; DatabaseName = 'documents'; KeyVaultKeyUrl = 'https://example.vault.azure.net/keys/cmk' } },
    @{ Name = 'validate-poc'; Parameters = @{ BaseUrl = 'https://example.test'; ApiClientId = $principal; SqlServerFqdn = 'example.database.windows.net'; DatabaseName = 'documents'; TenantId = $tenant } },
    @{ Name = 'test-separation-of-duties'; Parameters = @{ SqlFqdn = 'example.database.windows.net'; Database = 'documents'; TenantId = $tenant; SecretsFile = $secretsFile } }
)
function Run-Case($Case) {
    $arguments = $Case.Parameters
    & (Join-Path $scripts "$($Case.Name).ps1") @arguments *> $null
}
function Expect-CliFailure($Case, [string] $Operation) {
    $global:OboAzureCliTest.Calls.Clear()
    $global:OboAzureCliTest.FailAt = $Operation
    $rejected = $false
    try { Run-Case $Case } catch { $rejected = $_.Exception.Message -match 'Azure CLI failed \(exit 7\)' }
    Assert $rejected "$($Case.Name) did not propagate failure of $Operation."
    $last = $global:OboAzureCliTest.Calls[-1]
    Assert (($last[0..1] -join ' ') -eq $Operation -or ($last[0..2] -join ' ') -eq $Operation) "$($Case.Name) continued after failure of $Operation."
    Assert ($global:OboAzureCliTest.SqlCalls -eq 0) 'Failed Azure CLI operation was followed by a SQL operation.'
}
try {
    foreach ($case in $cases) {
        if ($case.Parameters.ContainsKey('SubscriptionId')) { Expect-CliFailure $case 'account set' }
        Expect-CliFailure $case 'account show'
    }
    foreach ($case in $cases | Where-Object { $_.Parameters.ContainsKey('TenantId') }) {
        $global:OboAzureCliTest.FailAt = ''
        $global:OboAzureCliTest.Tenant = '99999999-9999-9999-9999-999999999999'
        $global:OboAzureCliTest.Calls.Clear()
        $rejected = $false
        try { Run-Case $case } catch { $rejected = $_.Exception.Message -match 'tenant' }
        Assert $rejected "$($case.Name) accepted a mismatched tenant."
        Assert (-not ($global:OboAzureCliTest.Calls | Where-Object { $_[0] -ne 'account' })) 'Tenant mismatch reached resource or directory operations.'
        $global:OboAzureCliTest.Tenant = $tenant
    }
    Expect-CliFailure $cases[0] 'group create'
    Expect-CliFailure $cases[0] 'deployment group create'
    Expect-CliFailure $cases[1] 'acr list'
    Expect-CliFailure $cases[1] 'acr build'
    $global:OboAzureCliTest.RegistryExists = $false
    Expect-CliFailure $cases[1] 'acr create'
    $global:OboAzureCliTest.RegistryExists = $true
    foreach ($operation in @('identity show','role assignment list','containerapp registry','containerapp secret','containerapp update')) {
        Expect-CliFailure $cases[2] $operation
    }
    $global:OboAzureCliTest.RoleExists = $false
    Expect-CliFailure $cases[2] 'role assignment create'
    $global:OboAzureCliTest.RoleExists = $true
    Expect-CliFailure $cases[3] 'ad app list'
    Expect-CliFailure $cases[4] 'rest --method'
    Expect-CliFailure $cases[4] 'ad app permission'
    Expect-CliFailure $cases[5] 'account get-access-token'
    Expect-CliFailure $cases[6] 'account get-access-token'

    $global:OboAzureCliTest.FailAt = ''
    foreach ($case in $cases[0..2]) {
        $global:OboAzureCliTest.Calls.Clear()
        Run-Case $case
        foreach ($call in $global:OboAzureCliTest.Calls | Where-Object { $_[0] -ne 'account' }) {
            Assert ((Argument $call '--subscription') -eq $subscription) 'Resource operation omitted the explicit subscription.'
        }
        Assert (-not ($global:OboAzureCliTest.Calls | Where-Object { ($_[0..2] -join ' ') -eq 'role assignment create' })) 'An existing role assignment was recreated.'
    }
    $global:OboAzureCliTest.RoleExists = $false
    $global:OboAzureCliTest.Calls.Clear()
    Run-Case $cases[2]
    Assert (@($global:OboAzureCliTest.Calls | Where-Object { ($_[0..2] -join ' ') -eq 'role assignment create' }).Count -eq 1) 'Missing role was not created exactly once.'
    $global:OboAzureCliTest.RegistryExists = $false
    $global:OboAzureCliTest.Calls.Clear()
    Run-Case $cases[1]
    Assert (@($global:OboAzureCliTest.Calls | Where-Object { ($_[0..1] -join ' ') -eq 'acr create' }).Count -eq 1) 'Missing registry was not created exactly once.'
    Assert (@($global:OboAzureCliTest.Calls | Where-Object { ($_[0..1] -join ' ') -eq 'acr build' }).Count -eq 1) 'New registry was not followed by the image build.'

    . (Join-Path $scripts 'azure-common.ps1')
    $script:SubscriptionId = $subscription
    $global:OboAzureCliTest.Subscription = '99999999-9999-9999-9999-999999999999'
    $global:OboAzureCliTest.Calls.Clear()
    $rejected = $false
    try { Invoke-Az ad app list -o json } catch { $rejected = $_.Exception.Message -match 'context changed' }
    Assert $rejected 'Directory operation accepted a changed default subscription.'
    Assert ($global:OboAzureCliTest.Calls.Count -eq 1 -and $global:OboAzureCliTest.Calls[0][0] -eq 'account') 'Directory mutation occurred after context drift.'

    foreach ($case in $cases) {
        $scriptFile = Join-Path $scripts "$($case.Name).ps1"
        $ast = [Management.Automation.Language.Parser]::ParseFile($scriptFile, [ref]$null, [ref]$null)
        $unchecked = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'az' }, $true)
        Assert ($unchecked.Count -eq 0) "$($case.Name) bypasses the checked Azure CLI helper."
    }
    Write-Host 'PASS: legacy Azure CLI failures stop execution; tenant/subscription checked; role reuse preserved; no real Azure calls.'
} finally {
    foreach ($file in @($parameters, $secretFile, $secretsFile)) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    Remove-Item -LiteralPath $directory
    Remove-Variable -Name OboAzureCliTest -Scope Global
    $global:LASTEXITCODE = 0
}
