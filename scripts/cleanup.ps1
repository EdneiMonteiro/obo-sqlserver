<#
.SYNOPSIS
Request deletion of an explicitly selected PoC resource group (AKS or legacy ACA).
App registrations are separate; this command does not remove them or purge Key Vault.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [guid] $SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z0-9-]+$')]
    [string] $ResourceGroupName
)

$ErrorActionPreference = 'Stop'
$target = "subscription $SubscriptionId / resource group $ResourceGroupName"
if ($PSCmdlet.ShouldProcess($target, 'Delete the entire resource group and its resources')) {
    az group delete --subscription $SubscriptionId --name $ResourceGroupName --yes --no-wait --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Azure did not accept the resource group deletion request.' }
    Write-Host "Deletion requested for $target. Verify completion before removing local deployment state."
}
