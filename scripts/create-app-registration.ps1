param(
    [Parameter(Mandatory = $true)]
    [string] $TenantId,

    [Parameter(Mandatory = $false)]
    [string] $DisplayName = "obo-sqlserver-poc-api",

    [Parameter(Mandatory = $false)]
    [string] $AzureCliClientId = "04b07795-8ddb-461a-bbee-02f9e1bf7b46",

    [Parameter(Mandatory = $false)]
    [string] $SecretOutputPath
)

$ErrorActionPreference = "Stop"

# Well-known resource and permission IDs (Azure built-ins)
$AzureSqlAppId           = "022907d3-0f1b-48f7-badc-1ba6abab6d66"
$AzureSqlUserImpScopeId  = "c39ef2d1-04ce-46dc-8b5f-e9a5c60f0fc9"
$AzureKeyVaultAppId      = "cfa8b339-82a2-471a-a3c9-0fc0be7a4093"
$AzureKeyVaultUserImpId  = "f53da476-18e3-4152-8e01-aec403e6edc0"
$MicrosoftGraphAppId     = "00000003-0000-0000-c000-000000000000"
$GraphOpenIdScopeId      = "37f7f235-527c-4136-accd-4a02d197296e"
$GraphProfileScopeId     = "14dad69e-099b-42c9-810b-d002981feec1"
$GraphOfflineScopeId     = "7427e0e9-2fba-42fe-b0c0-848c9e6a8182"

Write-Host "Ensuring app registration '$DisplayName' exists..."
$existing = az ad app list --display-name $DisplayName --query "[0]" -o json --only-show-errors | ConvertFrom-Json
if ($existing) {
    Write-Host "App already exists. appId=$($existing.appId)"
    $app = $existing
} else {
    $app = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --only-show-errors -o json | ConvertFrom-Json
    Write-Host "Created app. appId=$($app.appId)"
}
$clientId  = $app.appId
$objectId  = $app.id
$apiUri    = "api://$clientId"

az ad app update --id $clientId --identifier-uris $apiUri --only-show-errors

$sp = az ad sp list --filter "appId eq '$clientId'" --query "[0]" -o json --only-show-errors | ConvertFrom-Json
if (-not $sp) {
    $sp = az ad sp create --id $clientId --only-show-errors -o json | ConvertFrom-Json
}
Write-Host "Service principal objectId=$($sp.id)"

# Step 1: declare the user_impersonation scope and required delegated permissions
$scopeGuid = [guid]::NewGuid().ToString()
$patch1 = @{
    api = @{
        oauth2PermissionScopes = @(@{
            adminConsentDescription = "Allow the app to access the $DisplayName on behalf of the signed-in user."
            adminConsentDisplayName = "Access $DisplayName"
            id = $scopeGuid
            isEnabled = $true
            type = "User"
            userConsentDescription = "Allow the app to access the $DisplayName on your behalf."
            userConsentDisplayName = "Access $DisplayName"
            value = "user_impersonation"
        })
        requestedAccessTokenVersion = 2
    }
    requiredResourceAccess = @(
        @{ resourceAppId = $AzureSqlAppId;        resourceAccess = @(@{ id = $AzureSqlUserImpScopeId; type = "Scope" }) },
        @{ resourceAppId = $AzureKeyVaultAppId;   resourceAccess = @(@{ id = $AzureKeyVaultUserImpId; type = "Scope" }) },
        @{ resourceAppId = $MicrosoftGraphAppId;  resourceAccess = @(
                @{ id = $GraphOpenIdScopeId;  type = "Scope" },
                @{ id = $GraphProfileScopeId; type = "Scope" },
                @{ id = $GraphOfflineScopeId; type = "Scope" }
            )
        }
    )
} | ConvertTo-Json -Depth 10 -Compress

$tmp1 = Join-Path $env:TEMP "appreg-step1-$([guid]::NewGuid().ToString('N')).json"
$patch1 | Out-File -LiteralPath $tmp1 -Encoding utf8
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$objectId" --headers "Content-Type=application/json" --body "@$tmp1" --only-show-errors
Remove-Item -LiteralPath $tmp1 -ErrorAction SilentlyContinue
Write-Host "Step 1 (scope + permissions) applied."

# Step 2: pre-authorize Azure CLI for the new scope so users can acquire tokens with `az account get-access-token`
$patch2 = @{ api = @{ preAuthorizedApplications = @(@{ appId = $AzureCliClientId; delegatedPermissionIds = @($scopeGuid) }) } } | ConvertTo-Json -Depth 10 -Compress
$tmp2 = Join-Path $env:TEMP "appreg-step2-$([guid]::NewGuid().ToString('N')).json"
$patch2 | Out-File -LiteralPath $tmp2 -Encoding utf8
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$objectId" --headers "Content-Type=application/json" --body "@$tmp2" --only-show-errors
Remove-Item -LiteralPath $tmp2 -ErrorAction SilentlyContinue
Write-Host "Step 2 (pre-authorize Azure CLI) applied."

Write-Host "Granting admin consent..."
az ad app permission admin-consent --id $clientId --only-show-errors

Write-Host "Creating client secret (1 year validity)..."
$secret = az ad app credential reset --id $clientId --append --display-name "poc-secret" --years 1 --only-show-errors -o json | ConvertFrom-Json

if (-not $SecretOutputPath) {
    Write-Warning "Secret was not written to disk. Save the value below in a secret store (Azure Key Vault, password manager). It will not be shown again by Microsoft Entra."
    Write-Host "CLIENT_SECRET=$($secret.password)"
} else {
    $secret.password | Out-File -LiteralPath $SecretOutputPath -Encoding utf8 -NoNewline
    Write-Host "Client secret written to: $SecretOutputPath"
}

Write-Host ""
Write-Host "Done. Use these values in your Container App configuration:"
Write-Host "  AzureAd__TenantId  = $TenantId"
Write-Host "  AzureAd__ClientId  = $clientId"
Write-Host "  AzureAd__Audience  = $clientId"
Write-Host "  AzureAd__ClientSecret = <stored as Container App secret 'azuread-client-secret'>"
