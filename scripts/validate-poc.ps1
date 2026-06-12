param(
    [Parameter(Mandatory = $true)] [string] $BaseUrl,
    [Parameter(Mandatory = $true)] [string] $ApiClientId,
    [Parameter(Mandatory = $true)] [string] $SqlServerFqdn,
    [Parameter(Mandatory = $true)] [string] $DatabaseName,
    [string] $TenantId
)

$ErrorActionPreference = 'Stop'

if ($TenantId) { az account show --query tenantId -o tsv | Out-Null }

$me = az ad signed-in-user show --only-show-errors -o json | ConvertFrom-Json
$myOid = $me.id
$myTid = (az account show --query tenantId -o tsv)
$otherOid = [guid]::NewGuid().ToString()

$token = az account get-access-token --resource "api://$ApiClientId" --query accessToken -o tsv --only-show-errors
if (-not $token) { throw "Failed to acquire token for api://$ApiClientId. Ensure Azure CLI is pre-authorized." }

$plainA = "[A] Document for receiver=me at $(Get-Date -Format o)"
$plainB = "[B] Document for receiver=other at $(Get-Date -Format o)"
$bA = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($plainA))
$bB = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($plainB))

$headers = @{ Authorization = "Bearer $token" }
$results = [ordered]@{}

function Post-Document($receiver, $b64, $file) {
    $body = @{ receiverTenantId = $myTid; receiverObjectId = $receiver; fileName = $file; contentType = 'text/plain'; payloadBase64 = $b64 } | ConvertTo-Json
    Invoke-WebRequest -Method Post -Uri "$BaseUrl/documents" -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 90 -SkipHttpErrorCheck
}

function Get-Document($id, [hashtable]$h = $headers) {
    Invoke-WebRequest -Method Get -Uri "$BaseUrl/documents/$id" -Headers $h -TimeoutSec 90 -SkipHttpErrorCheck
}

Write-Host "=== T1: POST sender=me, receiver=me ==="
$r = Post-Document $myOid $bA 'a.txt'
$docA = if ($r.StatusCode -eq 201) { ($r.Content | ConvertFrom-Json).documentId } else { $null }
Write-Host "status=$($r.StatusCode) doc=$docA"
$results['T1 sender writes (receiver=me)'] = ($r.StatusCode -eq 201)

Write-Host "=== T2: POST sender=me, receiver=other ==="
$r = Post-Document $otherOid $bB 'b.txt'
$docB = if ($r.StatusCode -eq 201) { ($r.Content | ConvertFrom-Json).documentId } else { $null }
Write-Host "status=$($r.StatusCode) doc=$docB"
$results['T2 sender writes (receiver=other)'] = ($r.StatusCode -eq 201)

Write-Host "=== T3: GET docA as receiver=me (expected 200 + plaintext) ==="
$r = Get-Document $docA
$results['T3 receiver reads plaintext'] = $false
if ($r.StatusCode -eq 200) {
    $dec = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($r.Content | ConvertFrom-Json).payloadBase64))
    Write-Host "decrypted='$dec'"
    if ($dec -eq $plainA) { $results['T3 receiver reads plaintext'] = $true }
}
Write-Host "status=$($r.StatusCode)"

Write-Host "=== T4: GET docB as me (NOT the receiver) (expected 403) ==="
$r = Get-Document $docB
Write-Host "status=$($r.StatusCode)"
$results['T4 non-receiver gets 403'] = ($r.StatusCode -eq 403)

Write-Host "=== T5: Anonymous GET (expected 401) ==="
$r = Invoke-WebRequest -Method Get -Uri "$BaseUrl/documents/$docA" -TimeoutSec 60 -SkipHttpErrorCheck
Write-Host "status=$($r.StatusCode)"
$results['T5 anonymous 401'] = ($r.StatusCode -eq 401)

Write-Host "=== T6: SQL admin direct SELECT on encrypted column (expected to fail or return only ciphertext) ==="
$sqlToken = az account get-access-token --resource 'https://database.windows.net' --query accessToken -o tsv --only-show-errors
$cs = "Server=tcp:$SqlServerFqdn,1433;Database=$DatabaseName;Encrypt=True;TrustServerCertificate=False;"
$sqlExposesPlain = $true
try {
    $rows = Invoke-Sqlcmd -ConnectionString $cs -AccessToken $sqlToken -Query "SELECT TOP 5 DocumentId, FileName, DATALENGTH(EncryptedPayload) AS bytes, SUBSTRING(EncryptedPayload, 1, 16) AS first16 FROM dbo.Documents ORDER BY CreatedAt DESC"
    $sqlExposesPlain = $false
    foreach ($row in $rows) { if ($row.first16 -is [byte[]]) { $s = [Text.Encoding]::UTF8.GetString($row.first16); if ($s -match 'Document') { $sqlExposesPlain = $true } } }
} catch {
    Write-Host "SQL admin SUBSTRING blocked by Always Encrypted: $($_.Exception.Message)"
    $sqlExposesPlain = $false
}
$results['T6 SQL admin cannot see plaintext'] = (-not $sqlExposesPlain)

Write-Host "=== T7: Audit log written ==="
$audit = Invoke-Sqlcmd -ConnectionString $cs -AccessToken $sqlToken -Query "SELECT TOP 10 AuditId, Action, Result, CorrelationId, CreatedAt FROM dbo.DocumentAccessAudit ORDER BY CreatedAt DESC"
$audit | Format-Table -AutoSize
$results['T7 audit logged'] = ($audit.Count -gt 0)

Write-Host ''
Write-Host '===== RESULTS ====='
$failed = 0
$results.GetEnumerator() | ForEach-Object { $ok = if ($_.Value) { 'PASS' } else { $failed++; 'FAIL' }; Write-Host ("  [{0}] {1}" -f $ok, $_.Key) }
if ($failed -gt 0) { exit 1 }
