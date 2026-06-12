param(
    [Parameter(Mandatory = $true)] [string] $SqlServerFqdn,
    [Parameter(Mandatory = $true)] [string] $DatabaseName,
    [Parameter(Mandatory = $true)] [string] $KeyVaultKeyUrl,
    [string] $CmkName = 'CMK_Documents_Akv',
    [string] $CekName = 'CEK_Documents'
)

$ErrorActionPreference = 'Stop'
Import-Module SqlServer -Force

$cs = "Server=tcp:$SqlServerFqdn,1433;Database=$DatabaseName;Encrypt=True;TrustServerCertificate=False;"

Write-Host "Acquiring SQL token..."
$sqlToken = az account get-access-token --resource 'https://database.windows.net' --query accessToken -o tsv --only-show-errors
if (-not $sqlToken) { throw "Failed to obtain SQL token." }

function Invoke-Sql([string]$query) {
    Invoke-Sqlcmd -ConnectionString $cs -AccessToken $sqlToken -Query $query -OutputAs DataRows
}

Invoke-Sql "SELECT 1 AS x" | Out-Null
$base = (Get-Module SqlServer).ModuleBase + '\coreclr'
foreach ($f in @('Azure.Core.dll','Azure.Identity.dll','Azure.Security.KeyVault.Keys.dll','Microsoft.Data.SqlClient.AlwaysEncrypted.AzureKeyVaultProvider.dll')) {
    [Reflection.Assembly]::LoadFrom((Join-Path $base $f)) | Out-Null
}

Add-Type -ReferencedAssemblies @([Azure.Core.TokenCredential].Assembly.Location) -CompilerOptions '/nowarn:CS1701,CS1702' -TypeDefinition @"
using System;
using System.Threading;
using System.Threading.Tasks;
using Azure.Core;

public class StaticTokenCredential : TokenCredential
{
    private readonly string _token;
    private readonly DateTimeOffset _expiry;
    public StaticTokenCredential(string token, DateTimeOffset expiry) { _token = token; _expiry = expiry; }
    public override AccessToken GetToken(TokenRequestContext ctx, CancellationToken ct) { return new AccessToken(_token, _expiry); }
    public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext ctx, CancellationToken ct) { return new ValueTask<AccessToken>(new AccessToken(_token, _expiry)); }
}
"@

$kvTokenInfo = az account get-access-token --resource 'https://vault.azure.net' -o json --only-show-errors | ConvertFrom-Json
$kvCred = [StaticTokenCredential]::new($kvTokenInfo.accessToken, [DateTimeOffset]::Parse($kvTokenInfo.expiresOn))

$cmkExists = (Invoke-Sql "SELECT COUNT(*) AS c FROM sys.column_master_keys WHERE name = N'$CmkName'").c -gt 0
$cekExists = (Invoke-Sql "SELECT COUNT(*) AS c FROM sys.column_encryption_keys WHERE name = N'$CekName'").c -gt 0

if (-not $cmkExists) {
    Write-Host "Creating Column Master Key [$CmkName] -> $KeyVaultKeyUrl"
    Invoke-Sql @"
CREATE COLUMN MASTER KEY [$CmkName]
WITH
(
    KEY_STORE_PROVIDER_NAME = N'AZURE_KEY_VAULT',
    KEY_PATH = N'$KeyVaultKeyUrl'
);
"@
} else { Write-Host "CMK [$CmkName] already exists." }

if (-not $cekExists) {
    Write-Host "Wrapping plaintext CEK via Azure Key Vault..."
    $kvProvider = [Microsoft.Data.SqlClient.AlwaysEncrypted.AzureKeyVaultProvider.SqlColumnEncryptionAzureKeyVaultProvider]::new($kvCred)

    $plainCek = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($plainCek)

    $encryptedCek = $kvProvider.EncryptColumnEncryptionKey($KeyVaultKeyUrl, 'RSA_OAEP', $plainCek)
    $hex = ($encryptedCek | ForEach-Object { '{0:X2}' -f $_ }) -join ''

    Write-Host "Encrypted CEK length: $($encryptedCek.Length) bytes"
    Invoke-Sql @"
CREATE COLUMN ENCRYPTION KEY [$CekName]
WITH VALUES
(
    COLUMN_MASTER_KEY = [$CmkName],
    ALGORITHM = 'RSA_OAEP',
    ENCRYPTED_VALUE = 0x$hex
);
"@
} else { Write-Host "CEK [$CekName] already exists." }

Write-Host "Creating tables (if not exists)..."
Invoke-Sql @"
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Documents' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.Documents
    (
        DocumentId uniqueidentifier NOT NULL CONSTRAINT PK_Documents PRIMARY KEY,
        SenderTenantId uniqueidentifier NOT NULL,
        SenderObjectId uniqueidentifier NOT NULL,
        ReceiverTenantId uniqueidentifier NOT NULL,
        ReceiverObjectId uniqueidentifier NOT NULL,
        FileName nvarchar(256) NOT NULL,
        ContentType nvarchar(128) NOT NULL,
        EncryptedPayload varbinary(max) ENCRYPTED WITH
        (
            COLUMN_ENCRYPTION_KEY = [$CekName],
            ENCRYPTION_TYPE = Randomized,
            ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256'
        ) NOT NULL,
        CreatedAt datetime2(7) NOT NULL CONSTRAINT DF_Documents_CreatedAt DEFAULT SYSUTCDATETIME(),
        ReadAt datetime2(7) NULL
    );
    CREATE INDEX IX_Documents_Receiver ON dbo.Documents (ReceiverTenantId, ReceiverObjectId, CreatedAt);
END
"@

Invoke-Sql @"
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DocumentAccessAudit' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.DocumentAccessAudit
    (
        AuditId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DocumentAccessAudit PRIMARY KEY,
        DocumentId uniqueidentifier NULL,
        Action nvarchar(64) NOT NULL,
        TenantId uniqueidentifier NOT NULL,
        ObjectId uniqueidentifier NOT NULL,
        Result nvarchar(32) NOT NULL,
        CorrelationId uniqueidentifier NOT NULL,
        CreatedAt datetime2(7) NOT NULL CONSTRAINT DF_DocumentAccessAudit_CreatedAt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_DocumentAccessAudit_DocumentId ON dbo.DocumentAccessAudit (DocumentId, CreatedAt);
END
"@

Write-Host "Done. CMK + CEK + tables ready in $DatabaseName."
