param(
    [Parameter(Mandatory=$true)] [string] $SqlFqdn,
    [Parameter(Mandatory=$true)] [string] $Database,
    [Parameter(Mandatory=$true)] [string] $TenantId,
    [Parameter(Mandatory=$true)] [string] $SecretsFile
)

# Reproduces the separation-of-duties end-to-end test.
# See docs/separation-of-duties.md for context.

$ErrorActionPreference = 'Continue'
Import-Module SqlServer -Force

$secrets = Get-Content -LiteralPath $SecretsFile -Raw | ConvertFrom-Json
$senderOid = $secrets.sender.oid
$readerOid = $secrets.reader.oid
$cs = "Server=tcp:$SqlFqdn,1433;Database=$Database;Encrypt=True;TrustServerCertificate=False;Column Encryption Setting=Enabled;"

function Get-AppToken($appId, $secret, $resource) {
    $body = "client_id=$appId&client_secret=$([uri]::EscapeDataString($secret))&scope=$resource/.default&grant_type=client_credentials"
    (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -ContentType 'application/x-www-form-urlencoded' -Body $body).access_token
}

Invoke-Sqlcmd -ConnectionString "Server=tcp:$SqlFqdn,1433;Database=$Database;Encrypt=True;TrustServerCertificate=False;" -AccessToken (Get-AppToken $secrets.sender.appId $secrets.sender.secret 'https://database.windows.net') -Query "SELECT 1" | Out-Null
$base = (Get-Module SqlServer).ModuleBase + '\coreclr'
foreach ($f in @('Azure.Core.dll','Azure.Identity.dll','Azure.Security.KeyVault.Keys.dll','Microsoft.Data.SqlClient.AlwaysEncrypted.AzureKeyVaultProvider.dll')) {
    [Reflection.Assembly]::LoadFrom((Join-Path $base $f)) | Out-Null
}

Add-Type -ReferencedAssemblies @([Azure.Core.TokenCredential].Assembly.Location) -CompilerOptions '/nowarn:CS1701,CS1702' -TypeDefinition @"
using System; using System.Threading; using System.Threading.Tasks; using Azure.Core;
public class StaticTokenCredential : TokenCredential {
  private readonly string _t; private readonly DateTimeOffset _e;
  public StaticTokenCredential(string token, DateTimeOffset exp) { _t = token; _e = exp; }
  public override AccessToken GetToken(TokenRequestContext c, CancellationToken k) { return new AccessToken(_t, _e); }
  public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext c, CancellationToken k) { return new ValueTask<AccessToken>(new AccessToken(_t, _e)); }
}
"@

function Invoke-WithAE($sqlToken, $kvToken, $query, $params = @{}) {
    $conn = New-Object Microsoft.Data.SqlClient.SqlConnection $cs
    $conn.AccessToken = $sqlToken
    $kvProvider = [Microsoft.Data.SqlClient.AlwaysEncrypted.AzureKeyVaultProvider.SqlColumnEncryptionAzureKeyVaultProvider]::new(
        [StaticTokenCredential]::new($kvToken, [DateTimeOffset]::UtcNow.AddMinutes(50)))
    $providers = New-Object 'System.Collections.Generic.Dictionary[string,Microsoft.Data.SqlClient.SqlColumnEncryptionKeyStoreProvider]'
    $providers.Add('AZURE_KEY_VAULT', $kvProvider)
    $conn.RegisterColumnEncryptionKeyStoreProvidersOnConnection($providers)
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $query
        foreach ($k in $params.Keys) {
            $v = $params[$k]
            if     ($v -is [guid])   { $p = $cmd.Parameters.Add("@$k", [System.Data.SqlDbType]::UniqueIdentifier); $p.Value = $v }
            elseif ($v -is [byte[]]) { $p = $cmd.Parameters.Add("@$k", [System.Data.SqlDbType]::VarBinary, -1);    $p.Value = $v }
            elseif ($v -is [string]) { $p = $cmd.Parameters.Add("@$k", [System.Data.SqlDbType]::NVarChar, 256);     $p.Value = $v }
            else                     { [void]$cmd.Parameters.AddWithValue("@$k", $v) }
        }
        if ($query.TrimStart() -like 'SELECT*') {
            $reader = $cmd.ExecuteReader()
            $rows = @()
            while ($reader.Read()) {
                $row = @{}
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $row[$reader.GetName($i)] = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
                }
                $rows += [pscustomobject]$row
            }
            $reader.Close()
            return ,$rows
        } else { [void]$cmd.ExecuteNonQuery(); return $null }
    } finally { $conn.Close() }
}

$results = [ordered]@{}
$senderSql = Get-AppToken $secrets.sender.appId $secrets.sender.secret 'https://database.windows.net'
$senderKv  = Get-AppToken $secrets.sender.appId $secrets.sender.secret 'https://vault.azure.net'

$docId = [guid]::NewGuid()
$plain = "[SECRET] Sent by sender SP to reader SP at $(Get-Date -Format o)"
$payload = [Text.Encoding]::UTF8.GetBytes($plain)

Write-Host "===== S1: sender INSERT (expected PASS) ====="
try {
    Invoke-WithAE $senderSql $senderKv "INSERT INTO dbo.Documents (DocumentId, SenderTenantId, SenderObjectId, ReceiverTenantId, ReceiverObjectId, FileName, ContentType, EncryptedPayload) VALUES (@d, @st, @so, @rt, @ro, @f, @c, @p)" @{ d=$docId; st=[guid]$TenantId; so=[guid]$senderOid; rt=[guid]$TenantId; ro=[guid]$readerOid; f='secret.txt'; c='text/plain'; p=$payload }
    Write-Host "  PASS doc=$docId"
    $results['S1 sender INSERT allowed'] = $true
} catch {
    Write-Host "  FAIL: $($_.Exception.GetBaseException().Message)"
    $results['S1 sender INSERT allowed'] = $false
}

Write-Host "===== S2: sender SELECT (expected FAIL) ====="
try {
    $null = Invoke-WithAE $senderSql $senderKv "SELECT TOP 1 FileName FROM dbo.Documents" @{}
    Write-Host "  UNEXPECTED PASS"
    $results['S2 sender SELECT denied'] = $false
} catch {
    $m = $_.Exception.GetBaseException().Message
    Write-Host "  EXPECTED FAIL: $m"
    $results['S2 sender SELECT denied'] = ($m -match 'permission was denied|SELECT permission')
}

$readerSql = Get-AppToken $secrets.reader.appId $secrets.reader.secret 'https://database.windows.net'
$readerKv  = Get-AppToken $secrets.reader.appId $secrets.reader.secret 'https://vault.azure.net'

Write-Host "===== R1: reader SELECT (expected PASS, plaintext) ====="
try {
    $r = Invoke-WithAE $readerSql $readerKv "SELECT TOP 1 DocumentId, FileName, EncryptedPayload FROM dbo.Documents ORDER BY CreatedAt DESC" @{}
    if ($r.Count -gt 0) {
        $row = $r[0]
        $dec = [Text.Encoding]::UTF8.GetString($row.EncryptedPayload)
        Write-Host "  PASS DocumentId=$($row.DocumentId) FileName=$($row.FileName)"
        Write-Host "  decrypted: '$dec'"
        $results['R1 reader reads plaintext'] = $true
    } else {
        Write-Host "  FAIL no rows"
        $results['R1 reader reads plaintext'] = $false
    }
} catch {
    Write-Host "  FAIL: $($_.Exception.GetBaseException().Message)"
    $results['R1 reader reads plaintext'] = $false
}

Write-Host "===== R2: reader INSERT (expected FAIL) ====="
try {
    $newId = [guid]::NewGuid()
    Invoke-WithAE $readerSql $readerKv "INSERT INTO dbo.Documents (DocumentId, SenderTenantId, SenderObjectId, ReceiverTenantId, ReceiverObjectId, FileName, ContentType, EncryptedPayload) VALUES (@d, @st, @so, @rt, @ro, @f, @c, @p)" @{ d=$newId; st=[guid]$TenantId; so=[guid]$readerOid; rt=[guid]$TenantId; ro=[guid]$senderOid; f='nope.txt'; c='text/plain'; p=$payload }
    Write-Host "  UNEXPECTED PASS"
    $results['R2 reader INSERT denied'] = $false
} catch {
    $m = $_.Exception.GetBaseException().Message
    Write-Host "  EXPECTED FAIL: $m"
    $results['R2 reader INSERT denied'] = ($m -match 'permission was denied|INSERT permission')
}

Write-Host "===== E1: current az login user SELECT (admin) ====="
$edneiSql = az account get-access-token --resource 'https://database.windows.net' --query accessToken -o tsv --only-show-errors
$edneiKv  = az account get-access-token --resource 'https://vault.azure.net'     --query accessToken -o tsv --only-show-errors
try {
    $r = Invoke-WithAE $edneiSql $edneiKv "SELECT TOP 1 DocumentId, FileName, EncryptedPayload FROM dbo.Documents ORDER BY CreatedAt DESC" @{}
    if ($r.Count -gt 0) {
        $row = $r[0]
        $dec = [Text.Encoding]::UTF8.GetString($row.EncryptedPayload)
        Write-Host "  RESULT: admin DID read plaintext: '$dec'"
        Write-Host "  ^ admin still has 'Key Vault Crypto User'. Remove it to make this fail."
        $results['E1 admin with KV access reads plaintext'] = $true
    } else {
        Write-Host "  FAIL no rows"
        $results['E1 admin with KV access reads plaintext'] = $false
    }
} catch {
    Write-Host "  RESULT (admin BLOCKED): $($_.Exception.GetBaseException().Message)"
    $results['E1 admin with KV access reads plaintext'] = $false
}

Write-Host ""
Write-Host "===== RESULTS ====="
$failed = 0
$results.GetEnumerator() | ForEach-Object {
    $ok = if ($_.Value) { 'PASS' } else { $failed++; 'FAIL' }
    Write-Host ("  [{0}] {1}" -f $ok, $_.Key)
}
if ($failed -gt 0) { exit 1 }
