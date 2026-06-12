param(
    [Parameter(Mandatory=$true)] [string] $SubscriptionId,
    [Parameter(Mandatory=$true)] [string] $ResourceGroupName,
    [Parameter(Mandatory=$true)] [string] $SqlServerFqdn,
    [Parameter(Mandatory=$true)] [string] $DatabaseName,
    [Parameter(Mandatory=$true)] [string] $KeyVaultName,
    [Parameter(Mandatory=$true)] [string] $TenantId,
    [Parameter(Mandatory=$false)] [string] $SenderName = 'sp-poc-sender',
    [Parameter(Mandatory=$false)] [string] $ReaderName = 'sp-poc-reader',
    [Parameter(Mandatory=$true)] [string] $SecretsOutputPath
)

# Demonstrates separation-of-duties with Always Encrypted:
# - sender SP gets INSERT only
# - reader SP gets SELECT only
# - both get Key Vault Crypto User
# Then validates that grants are enforced AND that AE+AKV is the real
# boundary protecting plaintext from a SQL admin.

$ErrorActionPreference = 'Stop'
Import-Module SqlServer -Force

az account set --subscription $SubscriptionId | Out-Null

function Ensure-Sp($name) {
    $existing = az ad app list --display-name $name --query "[0]" -o json --only-show-errors | ConvertFrom-Json
    if (-not $existing) {
        $app = az ad app create --display-name $name --sign-in-audience AzureADMyOrg --only-show-errors -o json | ConvertFrom-Json
        az ad sp create --id $app.appId --only-show-errors | Out-Null
        Write-Host "Created app+sp $name appId=$($app.appId)"
        return $app
    }
    Write-Host "App $name already exists appId=$($existing.appId)"
    return $existing
}

$senderApp = Ensure-Sp $SenderName
$readerApp = Ensure-Sp $ReaderName

$senderSecret = az ad app credential reset --id $senderApp.appId --append --display-name 'poc' --years 1 --only-show-errors -o json | ConvertFrom-Json
$readerSecret = az ad app credential reset --id $readerApp.appId --append --display-name 'poc' --years 1 --only-show-errors -o json | ConvertFrom-Json

$senderOid = az ad sp show --id $senderApp.appId --query id -o tsv
$readerOid = az ad sp show --id $readerApp.appId --query id -o tsv

@{
    sender = @{ appId = $senderApp.appId; oid = $senderOid; secret = $senderSecret.password };
    reader = @{ appId = $readerApp.appId; oid = $readerOid; secret = $readerSecret.password };
} | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $SecretsOutputPath -Encoding utf8
Write-Host "Secrets and metadata written to $SecretsOutputPath (NEVER commit)."

$kvId = az keyvault show -g $ResourceGroupName -n $KeyVaultName --query id -o tsv
foreach ($oid in @($senderOid, $readerOid)) {
    az role assignment create --assignee-object-id $oid --assignee-principal-type ServicePrincipal --role 'Key Vault Crypto User' --scope $kvId --only-show-errors -o none 2>$null
}
Write-Host "Key Vault Crypto User granted on $KeyVaultName."

$sqlToken = az account get-access-token --resource 'https://database.windows.net' --query accessToken -o tsv --only-show-errors
$cs = "Server=tcp:$SqlServerFqdn,1433;Database=$DatabaseName;Encrypt=True;TrustServerCertificate=False;"
$ddl = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$SenderName')
    CREATE USER [$SenderName] FROM EXTERNAL PROVIDER;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$ReaderName')
    CREATE USER [$ReaderName] FROM EXTERNAL PROVIDER;

GRANT INSERT ON dbo.Documents           TO [$SenderName];
GRANT INSERT ON dbo.DocumentAccessAudit TO [$SenderName];
GRANT SELECT ON dbo.Documents           TO [$ReaderName];
GRANT INSERT ON dbo.DocumentAccessAudit TO [$ReaderName];

GRANT VIEW ANY COLUMN MASTER KEY DEFINITION     TO [$SenderName];
GRANT VIEW ANY COLUMN ENCRYPTION KEY DEFINITION TO [$SenderName];
GRANT VIEW ANY COLUMN MASTER KEY DEFINITION     TO [$ReaderName];
GRANT VIEW ANY COLUMN ENCRYPTION KEY DEFINITION TO [$ReaderName];
"@
Invoke-Sqlcmd -ConnectionString $cs -AccessToken $sqlToken -Query $ddl
Write-Host "SQL contained users and grants applied."
