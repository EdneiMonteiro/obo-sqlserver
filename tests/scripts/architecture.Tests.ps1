$ErrorActionPreference = 'Stop'
$global:OboArchitectureTestState = @{
    Calls = [Collections.Generic.List[object]]::new()
    FailDelete = $false
}
function az {
    $global:OboArchitectureTestState.Calls.Add(@($args))
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'account' -and $args[1] -eq 'list') {
        return '[{"name":"Example","id":"22222222-2222-2222-2222-222222222222","tenantId":"11111111-1111-1111-1111-111111111111","state":"Enabled","isDefault":true}]'
    }
    if ($args[0] -eq 'provider' -and $args[1] -eq 'show') { return 'Registered' }
    if ($args[0] -eq 'group' -and $args[1] -eq 'delete') {
        if ($global:OboArchitectureTestState.FailDelete) { $global:LASTEXITCODE = 1 }
        return
    }
    throw 'Unexpected Azure operation in local architecture tests.'
}
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$preflight = Join-Path $repo 'scripts\preflight-azure.ps1'
$cleanup = Join-Path $repo 'scripts\cleanup.ps1'
$tenant = '11111111-1111-1111-1111-111111111111'
$subscription = '22222222-2222-2222-2222-222222222222'

foreach ($architecture in @('AKS', 'ACA')) {
    $global:OboArchitectureTestState.Calls.Clear()
    & $preflight -TenantId $tenant -Architecture $architecture *> $null
    $providers = @($global:OboArchitectureTestState.Calls | Where-Object { $_[0] -eq 'provider' })
    $names = @($providers | ForEach-Object { $_[[Array]::IndexOf($_, '--namespace') + 1] })
    $expected = if ($architecture -eq 'AKS') { @('Microsoft.ContainerService','Microsoft.Network','Microsoft.Storage','Microsoft.Compute') } else { @('Microsoft.App','Microsoft.OperationalInsights') }
    foreach ($name in $expected) { Assert ($names -contains $name) "$architecture omitted provider $name." }
    Assert ($names -contains 'Microsoft.ContainerRegistry') 'ACR must be included in both paths.'
    foreach ($call in $providers) {
        Assert ($call[[Array]::IndexOf($call, '--subscription') + 1] -eq $subscription) 'Provider query lost the explicit subscription.'
    }
    Assert (-not ($global:OboArchitectureTestState.Calls | Where-Object { $_[0] -eq 'account' -and $_[1] -eq 'set' })) 'Read-only preflight changed global context.'
}
Assert ((Get-Command $preflight).ScriptBlock.Ast.ParamBlock.Parameters |
    Where-Object { $_.Name.VariablePath.UserPath -eq 'Architecture' -and $_.DefaultValue.Value -eq 'AKS' }) 'Default architecture must be AKS.'
Assert (-not (Get-Command $preflight).Parameters.ContainsKey('ForecastsPath')) 'Functional preflight must not rank financial forecasts.'

$global:OboArchitectureTestState.Calls.Clear()
& $cleanup -SubscriptionId $subscription -ResourceGroupName 'rg-example' -WhatIf
Assert ($global:OboArchitectureTestState.Calls.Count -eq 0) 'Cleanup WhatIf contacted Azure.'
$parameter = (Get-Command $cleanup).Parameters['ResourceGroupName']
Assert ($parameter.Attributes | Where-Object { $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory }) 'Cleanup must require an explicit RG.'
& $cleanup -SubscriptionId $subscription -ResourceGroupName 'rg-example' -Confirm:$false
Assert ($global:OboArchitectureTestState.Calls.Count -eq 1) 'Cleanup should submit exactly one explicit deletion.'
$call = $global:OboArchitectureTestState.Calls[0]
Assert ($call[[Array]::IndexOf($call, '--subscription') + 1].ToString() -eq $subscription) 'Cleanup target subscription changed.'
Assert ($call[[Array]::IndexOf($call, '--name') + 1] -eq 'rg-example') 'Cleanup target RG changed.'
$global:OboArchitectureTestState.FailDelete = $true
$rejected = $false
try { & $cleanup -SubscriptionId $subscription -ResourceGroupName 'rg-example' -Confirm:$false } catch { $rejected = $true }
Assert $rejected 'Failed deletion must not be reported as accepted.'
Remove-Variable -Name OboArchitectureTestState -Scope Global
$global:LASTEXITCODE = 0
Write-Host 'PASS: AKS/legacy preflight and explicit, WhatIf-capable cleanup; no real Azure calls.'
