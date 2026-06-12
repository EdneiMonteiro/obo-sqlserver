param(
    [Parameter(Mandatory = $true)]
    [string] $SqlServerName,

    [Parameter(Mandatory = $true)]
    [string] $DatabaseName,

    [Parameter(Mandatory = $true)]
    [string] $KeyVaultName,

    [Parameter(Mandatory = $false)]
    [string] $KeyName = "cmk-documents"
)

$ErrorActionPreference = "Stop"

$key = az keyvault key show --vault-name $KeyVaultName --name $KeyName -o json | ConvertFrom-Json
$keyUrl = $key.key.kid

Write-Host "Key Vault key URL:"
Write-Host $keyUrl
Write-Host ""
Write-Host "Next step:"
Write-Host "1. Use SSMS or the SqlServer PowerShell module with Always Encrypted enabled to generate the CEK encrypted value."
Write-Host "2. Replace \$(KeyVaultKeyUrl) and \$(CekEncryptedValue) in sql\001-schema-always-encrypted-template.sql."
Write-Host "3. Run the generated script against $SqlServerName / $DatabaseName."
Write-Host ""
Write-Host "Important: the SQL admin used for validation must not have Key Vault unwrap/decrypt permissions."

