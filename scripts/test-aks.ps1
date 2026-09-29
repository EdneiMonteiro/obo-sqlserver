param(
    [Parameter(Mandatory)] [guid] $SubscriptionId,
    [Parameter(Mandatory)] [string] $StatePath,
    [switch] $FromPrivateNetwork,
    [switch] $IncludeSegregation
)
. "$PSScriptRoot\aks-common.ps1"
$script:SubscriptionId = $SubscriptionId.ToString()
$StatePath = [IO.Path]::GetFullPath($StatePath)
$script:OutputDirectory = Split-Path $StatePath -Parent
$script:KubeConfig = Join-Path $script:OutputDirectory 'kubeconfig.local'
$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
if ($state.subscriptionId -ne $SubscriptionId.ToString()) { throw 'State/subscription mismatch.' }
$validation = $null
if ($IncludeSegregation) {
    $validationPath = Join-Path $script:OutputDirectory 'validation.local.json'
    if (-not (Test-Path -LiteralPath $validationPath)) { throw 'Run setup-validation.ps1 before requesting segregation tests.' }
    $validation = Get-Content -LiteralPath $validationPath -Raw | ConvertFrom-Json
    if (-not $validation.ready -or $validation.subscriptionId -ne $state.subscriptionId -or
        $validation.tenantId -ne $state.tenantId -or $validation.resourceGroup -ne $state.resourceGroup -or
        $validation.clusterName -ne $state.outputs.clusterName.value -or
        $validation.sqlFqdn -ne $state.outputs.sqlFqdn.value -or $validation.databaseName -ne $state.outputs.databaseName.value) {
        throw 'Validation setup is incomplete or belongs to another target.'
    }
    $null = Get-ValidationIdentities $validation
}
$storage = Invoke-Az storage account show -g $state.resourceGroup -n $state.outputs.storageAccount.value `
    --query '{publicNetworkAccess:publicNetworkAccess,allowBlobPublicAccess:allowBlobPublicAccess}' -o json | ConvertFrom-Json
if ($storage.publicNetworkAccess -ne 'Disabled' -or $storage.allowBlobPublicAccess -ne $false) {
    throw 'Storage public access is not disabled.'
}
$url = "https://$($state.outputs.publicHost.value)"
$response = Invoke-WebRequest "$url/" -SkipHttpErrorCheck
if ($response.StatusCode -ne 200 -or $response.Content -notmatch 'Documentos protegidos') { throw 'SPA not served.' }
$session = Invoke-RestMethod "$url/bff/session"
if ($session.authenticated -ne $false) { throw 'Anonymous session unexpectedly authenticated.' }
$anonymous = Invoke-WebRequest "$url/api/documents/$([guid]::NewGuid())" -SkipHttpErrorCheck
if ($anonymous.StatusCode -ne 401) { throw 'Anonymous API access was not denied with 401.' }
$direct = Invoke-WebRequest "$($state.outputs.blobContainerUrl.value)/index.html" -SkipHttpErrorCheck
if ($FromPrivateNetwork) {
    $errorCode = ([xml]$direct.Content.TrimStart([char]0xFEFF)).Error.Code
    if ($direct.StatusCode -ne 409 -or $errorCode -ne 'PublicAccessNotPermitted') {
        throw "Anonymous Blob read inside VNet expected 409/PublicAccessNotPermitted; got $($direct.StatusCode)/$errorCode."
    }
    Write-Host 'PASS: SPA/HTTPS, anonymous API 401, and Blob anonymous access explicitly disabled (409/PublicAccessNotPermitted). External network probe still required.'
} else {
    if ($direct.StatusCode -ne 403) { throw 'Blob private origin was not denied with 403 from outside the VNet.' }
    Write-Host 'PASS: SPA/HTTPS, anonymous 401, Storage public access disabled and private Blob origin 403 from outside the VNet.'
}
if ($IncludeSegregation) {
    Initialize-Kubernetes $state
    $document = [guid]::NewGuid().ToString()
    foreach ($actor in @('sender','reader','admin-with-key','admin-without-key')) {
        Start-Operation -Mode $actor -State $state -DocumentId $document -Validation $validation
    }
    Write-Host 'PASS: optional direct SQL/Key Vault segregation.'
}
Write-Host 'Browser login/OBO must be exercised separately with the live browser suite.'
