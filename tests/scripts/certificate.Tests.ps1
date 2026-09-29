$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\scripts\aks-common.ps1"
$script:KubeConfig = 'test-config'
$global:OboTlsTest = @{
    Existing = $null
    Applied = [Collections.Generic.List[object]]::new()
    Deleted = [Collections.Generic.List[object]]::new()
}
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function kubectl {
    $global:LASTEXITCODE = 0
    $arguments = @($args | Select-Object -Skip 2)
    if ($arguments[0] -eq 'get') {
        if ($null -ne $global:OboTlsTest.Existing) {
            return $global:OboTlsTest.Existing | ConvertTo-Json -Depth 8
        }
        return
    }
    if ($arguments[0] -eq 'delete') {
        $global:OboTlsTest.Deleted.Add($arguments)
        $global:OboTlsTest.Existing = $null
        return
    }
    if ($arguments[0] -eq 'apply') {
        $object = ($input | Out-String) | ConvertFrom-Json
        if ($null -ne $global:OboTlsTest.Existing -and $global:OboTlsTest.Existing.type -ne $object.type) {
            throw 'Kubernetes validation: Secret type is immutable.'
        }
        $global:OboTlsTest.Applied.Add($object)
        $global:OboTlsTest.Existing = $object
        return
    }
    throw 'Unexpected kubectl operation.'
}
try {
    foreach ($existing in @($null, [pscustomobject]@{ type = 'Opaque' },
        [pscustomobject]@{ type = 'Opaque'; data = [pscustomobject]@{} })) {
        $global:OboTlsTest.Existing = $existing
        $global:OboTlsTest.Applied.Clear()
        $global:OboTlsTest.Deleted.Clear()
        Initialize-IngressTlsSecret
        Assert ($global:OboTlsTest.Applied.Count -eq 1) 'Missing/empty placeholder was not initialized.'
        $secret = $global:OboTlsTest.Applied[0]
        Assert ($secret.type -eq 'kubernetes.io/tls') 'Placeholder must have the final immutable TLS type.'
        Assert ($secret.data.PSObject.Properties['tls.crt'] -and $secret.data.PSObject.Properties['tls.key']) 'TLS placeholder requires both keys.'
        Assert ($secret.data.'tls.crt' -eq '' -and $secret.data.'tls.key' -eq '') 'Placeholder must not invent a certificate.'
        Assert ($global:OboTlsTest.Deleted.Count -eq $(if ($null -eq $existing) { 0 } else { 1 })) 'Only an empty legacy placeholder may be deleted.'
        if ($global:OboTlsTest.Deleted.Count) {
            Assert ($global:OboTlsTest.Deleted[0][2] -eq 'obo-tls') 'Wrong Secret selected for replacement.'
        }
        $global:OboTlsTest.Existing.data.'tls.crt' = 'synthetic-existing-certificate'
        $global:OboTlsTest.Existing.data.'tls.key' = 'synthetic-existing-key'
        $global:OboTlsTest.Applied.Clear()
        $global:OboTlsTest.Deleted.Clear()
        Initialize-IngressTlsSecret
        Assert ($global:OboTlsTest.Applied.Count -eq 0 -and $global:OboTlsTest.Deleted.Count -eq 0) 'Existing TLS material was modified.'
    }
    foreach ($existing in @(
        [pscustomobject]@{ type = 'Opaque'; data = [pscustomobject]@{ 'tls.crt' = 'existing-material' } },
        [pscustomobject]@{ type = 'kubernetes.io/basic-auth'; data = [pscustomobject]@{} }
    )) {
        $global:OboTlsTest.Existing = $existing
        $global:OboTlsTest.Applied.Clear()
        $global:OboTlsTest.Deleted.Clear()
        $failed = $false
        try { Initialize-IngressTlsSecret } catch { $failed = $_.Exception.Message -match 'Refusing to replace' }
        Assert $failed 'Unexpected Secret must fail instead of being overwritten.'
        Assert ($global:OboTlsTest.Applied.Count -eq 0 -and $global:OboTlsTest.Deleted.Count -eq 0) 'Unexpected Secret was mutated.'
    }
    Write-Host 'PASS: immutable TLS type, empty-placeholder migration and existing certificate preservation; Kubernetes mocked.'
} finally {
    Remove-Variable -Name OboTlsTest -Scope Global
    $global:LASTEXITCODE = 0
}
