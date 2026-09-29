$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\scripts\aks-common.ps1"
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
$subscription = '11111111-1111-1111-1111-111111111111'
$tenant = '22222222-2222-2222-2222-222222222222'
$outputs = [pscustomobject]@{ registryHost = [pscustomobject]@{ value = 'example.azurecr.io' } }
$arguments = @{
    SubscriptionId = $subscription; TenantId = $tenant; ResourceGroupName = 'rg-example'
    Api = @{ appId = 'api' }; Bff = @{ appId = 'bff' }; Outputs = $outputs
    IstioRevision = 'asm-1-30'; SqlAdminObjectId = '33333333-3333-3333-3333-333333333333'
    ApplicationUsers = @()
}
$previous = [pscustomobject]@{
    subscriptionId = $subscription; tenantId = $tenant; resourceGroup = 'rg-example'
    outputs = $outputs; tag = 'previous-app'; operationsTag = 'previous-operations'
}
$state = [pscustomobject](New-DeploymentState @arguments -PreviousState $previous)
Assert ($state.tag -eq 'previous-app' -and $state.operationsTag -eq 'previous-operations') 'Infrastructure reapply lost existing image tags.'
Assert (-not $state.infrastructureReady) 'New infrastructure state must await federation completion.'
Assert-PublishedImages $state
$fresh = [pscustomobject](New-DeploymentState @arguments)
Assert ($null -eq $fresh.tag -and $null -eq $fresh.operationsTag) 'Fresh infrastructure invented unbuilt image tags.'
$failed = $false
try { Assert-PublishedImages $fresh } catch { $failed = $_.Exception.Message -match 'No published image tags' }
Assert $failed 'SkipImageBuild must reject a fresh, unbuilt deployment.'
$previous.resourceGroup = 'rg-other'
$failed = $false
try { New-DeploymentState @arguments -PreviousState $previous | Out-Null } catch { $failed = $true }
Assert $failed 'State from another target was accepted.'
$previous.resourceGroup = 'rg-example'
$previous.outputs = [pscustomobject]@{ registryHost = [pscustomobject]@{ value = 'other.azurecr.io' } }
$moved = [pscustomobject](New-DeploymentState @arguments -PreviousState $previous)
Assert ($null -eq $moved.tag -and $null -eq $moved.operationsTag) 'Tags from another registry were reused.'
Write-Host 'PASS: infrastructure state preserves built tags and rejects unbuilt/mismatched image state.'
