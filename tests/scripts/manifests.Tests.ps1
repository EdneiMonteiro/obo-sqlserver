$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\scripts\aks-common.ps1"
$script:OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) "obo-manifest-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $script:OutputDirectory | Out-Null
$values = @{
    TENANT_ID = '11111111-1111-1111-1111-111111111111'
    API_CLIENT_ID = '22222222-2222-2222-2222-222222222222'
    BFF_CLIENT_ID = '33333333-3333-3333-3333-333333333333'
    ISTIO_REVISION = 'asm-1-30'; PUBLIC_HOST = 'example.test'
    BLOB_URL = 'https://example.blob.core.windows.net/spa'; SQL_FQDN = 'example.database.windows.net'
    DATABASE = 'documents'; REGISTRY = 'example.azurecr.io'; TAG = 'test'
}
function Get-PodRevisions([string] $Manifest) {
    $templates = [regex]::Matches($Manifest, '(?ms)^  template:\r?\n(.*?)(?=^---|\z)')
    if ($templates.Count -ne 2) { throw 'Expected the BFF and API pod templates.' }
    return [regex]::Matches(($templates.Value -join "`n"), '(?m)^        checksum/manifest: "([a-f0-9]{64})"\r?$')
}
try {
    $path = Render-Manifest 'apps' $values
    $content = Get-Content -LiteralPath $path -Raw
    if ($content -notmatch 'AzureAd__ClientCredentials__0__SourceType') {
        throw 'Rendering changed .NET configuration separators.'
    }
    if ($content -cmatch '__[A-Z_]+__') { throw 'Rendering left uppercase placeholders.' }
    $revisions = @(Get-PodRevisions $content)
    if ($revisions.Count -ne 2) { throw 'Both pod templates must include the rendered manifest revision.' }
    $revision = $revisions[0].Groups[1].Value
    if ($revisions[1].Groups[1].Value -ne $revision) { throw 'Pod templates have inconsistent revisions.' }
    $unchanged = Get-Content -LiteralPath (Render-Manifest 'apps' $values) -Raw
    if ($unchanged -cne $content) { throw 'Identical inputs changed the pod templates.' }
    $values['UNUSED_VALUE'] = 'not-rendered'
    $unchanged = Get-Content -LiteralPath (Render-Manifest 'apps' $values) -Raw
    if ($unchanged -cne $content) { throw 'An unused parameter triggered a rollout.' }
    $values.Remove('UNUSED_VALUE')
    foreach ($key in @('TENANT_ID','API_CLIENT_ID','BFF_CLIENT_ID','PUBLIC_HOST','BLOB_URL','SQL_FQDN','DATABASE')) {
        $changedValues = $values.Clone()
        $changedValues[$key] = if ($key -like '*_ID') { '44444444-4444-4444-4444-444444444444' } else { 'changed.test' }
        $changed = Get-Content -LiteralPath (Render-Manifest 'apps' $changedValues) -Raw
        $changedRevisions = @(Get-PodRevisions $changed)
        if ($changedRevisions.Count -ne 2 -or @($changedRevisions | Where-Object { $_.Groups[1].Value -eq $revision }).Count) {
            throw "Changing $key did not update both pod templates."
        }
        $images = [regex]::Matches($content, '(?m)^\s+image: .+$').Value -join "`n"
        $changedImages = [regex]::Matches($changed, '(?m)^\s+image: .+$').Value -join "`n"
        if ($images -cne $changedImages) { throw "The $key regression fixture changed the images." }
    }
    $values.Remove('BFF_CLIENT_ID')
    $rejected = $false
    try { $null = Render-Manifest 'apps' $values } catch { $rejected = $_.Exception.Message -match '__BFF_CLIENT_ID__' }
    if (-not $rejected) { throw 'Missing BFF client ID was not rejected.' }
    Write-Host 'PASS: configuration changes update both pod templates with unchanged images; identical rendering is stable; unresolved placeholders rejected.'
} finally {
    $file = Join-Path $script:OutputDirectory 'apps.local.yaml'
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    Remove-Item -LiteralPath $script:OutputDirectory
}
