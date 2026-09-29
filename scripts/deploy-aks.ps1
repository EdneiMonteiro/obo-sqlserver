param(
    [Parameter(Mandatory)] [guid] $SubscriptionId,
    [Parameter(Mandatory)] [guid] $TenantId,
    [string] $ResourceGroupName = 'rg-obo-aks-poc-brs-001',
    [string] $Location = 'brazilsouth',
    [string] $KubernetesVersion = '1.35.8',
    [string] $IstioRevision = 'asm-1-30',
    [string[]] $OperatorCidrs = @(),
    [guid[]] $SenderObjectIds = @(),
    [guid[]] $ReceiverObjectIds = @(),
    [string] $OutputDirectory = '.\.local\aks',
    [switch] $InfrastructureOnly,
    [switch] $SkipInfrastructure,
    [switch] $BuildImagesOnly,
    [switch] $SkipImageBuild
)

. "$PSScriptRoot\aks-common.ps1"
$script:SubscriptionId = $SubscriptionId.ToString()
$script:OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $script:OutputDirectory -Force | Out-Null
$script:KubeConfig = Join-Path $script:OutputDirectory 'kubeconfig.local'
$statePath = Join-Path $script:OutputDirectory 'deployment.local.json'
$repo = Split-Path $PSScriptRoot -Parent
if ($BuildImagesOnly -and $SkipImageBuild) { throw 'BuildImagesOnly and SkipImageBuild are mutually exclusive.' }
if ($InfrastructureOnly -and ($SkipInfrastructure -or $BuildImagesOnly -or $SkipImageBuild)) {
    throw 'InfrastructureOnly cannot be combined with publication flags.'
}
if ($ResourceGroupName -notmatch '^[a-zA-Z0-9-]+$') { throw 'ResourceGroupName must contain only letters, digits and hyphens.' }
$previousState = $null
if (Test-Path -LiteralPath $statePath) {
    $previousState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($previousState.subscriptionId -ne $SubscriptionId.ToString() -or $previousState.tenantId -ne $TenantId.ToString() -or
        $previousState.resourceGroup -ne $ResourceGroupName) { throw 'Deployment state does not match the explicit target.' }
}
if ($SkipInfrastructure -and ($PSBoundParameters.ContainsKey('SenderObjectIds') -or $PSBoundParameters.ContainsKey('ReceiverObjectIds'))) {
    throw 'Application user changes require the infrastructure step to apply Key Vault roles.'
}
if ($null -ne $previousState -and $previousState.PSObject.Properties['applicationUsers']) {
    if (-not $PSBoundParameters.ContainsKey('SenderObjectIds')) { $SenderObjectIds = @($previousState.applicationUsers | Where-Object canSend | ForEach-Object objectId) }
    if (-not $PSBoundParameters.ContainsKey('ReceiverObjectIds')) { $ReceiverObjectIds = @($previousState.applicationUsers | Where-Object canRead | ForEach-Object objectId) }
}
$applicationUsers = @(@($SenderObjectIds) + @($ReceiverObjectIds) | Select-Object -Unique | ForEach-Object {
    if ($_ -eq [guid]::Empty) { throw 'Application user object IDs cannot be empty.' }
    @{ objectId = $_.ToString(); canSend = $SenderObjectIds -contains $_; canRead = $ReceiverObjectIds -contains $_ }
})

$subscription = Invoke-Az rest --method GET --url "https://management.azure.com/subscriptions/$SubscriptionId`?api-version=2022-12-01" -o json | ConvertFrom-Json
if ($subscription.tenantId -ne $TenantId.ToString() -or $subscription.state -ne 'Enabled') {
    throw 'Subscription is disabled or belongs to a different tenant.'
}
& az account set --subscription $SubscriptionId --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Could not select the verified Azure CLI context.' }

function Ensure-App([string] $Name) {
    $apps = @(Invoke-Az ad app list --display-name $Name -o json | ConvertFrom-Json | Where-Object displayName -eq $Name)
    if ($apps.Count -gt 1) { throw "Multiple applications named $Name. Refusing ambiguous updates." }
    if ($apps.Count -eq 1) {
        $app = $apps[0]
        if ($app.tags -notcontains 'obo-sqlserver-poc' -or $app.tags -notcontains $ResourceGroupName) {
            throw "Application $Name is not owned by this PoC."
        }
    } else {
        $app = Invoke-Az ad app create --display-name $Name --sign-in-audience AzureADMyOrg -o json | ConvertFrom-Json
        Invoke-GraphPatch "https://graph.microsoft.com/v1.0/applications/$($app.id)" @{ tags = @('obo-sqlserver-poc', $ResourceGroupName) }
    }
    $principals = @(Invoke-Az ad sp list --filter "appId eq '$($app.appId)'" -o json | ConvertFrom-Json)
    $sp = if ($principals.Count) { $principals[0] } else { Invoke-Az ad sp create --id $app.appId -o json | ConvertFrom-Json }
    return @{ application = $app; principal = $sp }
}

function Ensure-Federation($App, [string] $Issuer, [string] $Subject) {
    $entries = @(Invoke-Az ad app federated-credential list --id $App.id -o json | ConvertFrom-Json)
    $matching = @($entries | Where-Object name -eq 'aks-workload')
    if ($matching.Count) {
        if ($matching[0].issuer -ne $Issuer -or $matching[0].subject -ne $Subject) {
            throw 'Existing federation differs from this cluster. Refusing to replace it implicitly.'
        }
        return
    }
    $path = Join-Path $script:OutputDirectory "$($App.appId)-federation.local.json"
    @{ name = 'aks-workload'; issuer = $Issuer; subject = $Subject; audiences = @('api://AzureADTokenExchange') } |
        ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
    Invoke-Az ad app federated-credential create --id $App.id --parameters "@$path" -o none
}

if (-not $SkipInfrastructure) {
    $operator = Invoke-Az rest --method GET --url 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName' -o json | ConvertFrom-Json
    $api = Ensure-App "obo-api-$ResourceGroupName"
    $bff = Ensure-App "obo-bff-$ResourceGroupName"
    $existingScopes = @($api.application.api.oauth2PermissionScopes | Where-Object value -eq 'user_impersonation')
    $scopeId = if ($existingScopes.Count) { $existingScopes[0].id } else { [guid]::NewGuid().ToString() }
    Invoke-GraphPatch "https://graph.microsoft.com/v1.0/applications/$($api.application.id)" @{
        identifierUris = @("api://$($api.application.appId)")
        api = @{
            requestedAccessTokenVersion = 2
            oauth2PermissionScopes = @(@{
                id = $scopeId; value = 'user_impersonation'; isEnabled = $true; type = 'Admin'
                adminConsentDisplayName = 'Access OBO documents'
                adminConsentDescription = 'Access documents on behalf of the signed-in user.'
            })
        }
        requiredResourceAccess = @(
            @{ resourceAppId = '022907d3-0f1b-48f7-badc-1ba6abab6d66'; resourceAccess = @(@{ id = 'c39ef2d1-04ce-46dc-8b5f-e9a5c60f0fc9'; type = 'Scope' }) },
            @{ resourceAppId = 'cfa8b339-82a2-471a-a3c9-0fc0be7a4093'; resourceAccess = @(@{ id = 'f53da476-18e3-4152-8e01-aec403e6edc0'; type = 'Scope' }) }
        )
    }
    Invoke-GraphPatch "https://graph.microsoft.com/v1.0/applications/$($bff.application.id)" @{
        requiredResourceAccess = @(@{
            resourceAppId = $api.application.appId; resourceAccess = @(@{ id = $scopeId; type = 'Scope' })
        })
    }
    Invoke-Az ad app permission admin-consent --id $api.application.appId
    Invoke-Az ad app permission admin-consent --id $bff.application.appId
    if ($OperatorCidrs.Count -eq 0) {
        $ip = (Invoke-RestMethod 'https://api.ipify.org?format=json').ip
        $OperatorCidrs = @("$ip/32")
        Write-Warning 'Using one observed egress IP. Supply approved -OperatorCidrs and ensure a stable administrative network path.'
    }
    foreach ($cidr in $OperatorCidrs) {
        $parts = $cidr.Split('/')
        $address = $null
        if ($parts.Count -ne 2 -or -not [Net.IPAddress]::TryParse($parts[0], [ref]$address) -or
            $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
            $parts[1] -notmatch '^([1-9]|[12][0-9]|3[0-2])$') {
            throw "Invalid or unrestricted operator IPv4 CIDR: $cidr"
        }
    }
    $parameters = @{
        location = @{ value = $Location }; operatorCidrs = @{ value = @($OperatorCidrs) }
        operatorObjectId = @{ value = $operator.id }; sqlAdminLogin = @{ value = $operator.userPrincipalName }
        bffPrincipalId = @{ value = $bff.principal.id }; cryptoUserObjectIds = @{ value = @($applicationUsers | ForEach-Object objectId) }
        kubernetesVersion = @{ value = $KubernetesVersion }; istioRevision = @{ value = $IstioRevision }
    }
    $parameterPath = Join-Path $script:OutputDirectory 'aks.parameters.local.json'
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parameterPath -Encoding utf8
    $exists = Invoke-Az group exists --name $ResourceGroupName -o tsv
    if ($exists -eq 'true') {
        $group = Invoke-Az group show --name $ResourceGroupName -o json | ConvertFrom-Json
        if ($group.tags.workload -ne 'obo-sqlserver') { throw 'Existing resource group is not owned by this PoC.' }
    } else {
        Invoke-Az group create --name $ResourceGroupName --location $Location --tags workload=obo-sqlserver environment=poc -o none
    }
    $template = Join-Path $repo 'infra\bicep\aks.bicep'
    Invoke-Az deployment group what-if -g $ResourceGroupName --template-file $template --parameters "@$parameterPath" --result-format ResourceIdOnly
    $deployment = Invoke-Az deployment group create -g $ResourceGroupName --name obo-aks --template-file $template --parameters "@$parameterPath" -o json | ConvertFrom-Json
    $state = New-DeploymentState -SubscriptionId $SubscriptionId.ToString() -TenantId $TenantId.ToString() `
        -ResourceGroupName $ResourceGroupName -Api $api.application -Bff $bff.application `
        -Outputs $deployment.properties.outputs -IstioRevision $IstioRevision -SqlAdminObjectId $operator.id `
        -ApplicationUsers $applicationUsers -PreviousState $previousState
    $state | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $statePath -Encoding utf8
    Ensure-Federation $api.application $state.outputs.oidcIssuer.value 'system:serviceaccount:obo:api'
    Ensure-Federation $bff.application $state.outputs.oidcIssuer.value 'system:serviceaccount:obo:bff'
    Invoke-GraphPatch "https://graph.microsoft.com/v1.0/applications/$($bff.application.id)" @{
        web = @{ redirectUris = @("https://$($state.outputs.publicHost.value)/signin-oidc", "https://$($state.outputs.publicHost.value)/signout-callback-oidc") }
    }
    $state.infrastructureReady = $true
    $state | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $statePath -Encoding utf8
    if ($InfrastructureOnly) { Write-Host "Infrastructure ready. State: $statePath"; return }
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.subscriptionId -ne $SubscriptionId.ToString() -or $state.tenantId -ne $TenantId.ToString() -or $state.resourceGroup -ne $ResourceGroupName) {
    throw 'Deployment state does not match the explicit target.'
}
if (-not $state.infrastructureReady) { throw 'Infrastructure/federation setup is incomplete. Rerun without -SkipInfrastructure.' }
if (-not $state.PSObject.Properties['applicationUsers'] -or -not $state.PSObject.Properties['sqlAdminObjectId']) {
    throw 'Deployment state needs explicit application users. Re-run the infrastructure step with SenderObjectIds/ReceiverObjectIds.'
}
if (-not $SkipImageBuild) {
    $state.tag = "poc-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
    Push-Location $repo
    try {
        foreach ($image in @(
            @{ name = 'obo-api'; file = 'Dockerfile' },
            @{ name = 'obo-bff'; file = 'src\bff\Dockerfile' },
            @{ name = 'obo-operations'; file = 'src\operations\Dockerfile' }
        )) {
            Write-Host "Building $($image.name):$($state.tag) in ACR..."
            Invoke-Az acr build -r $state.outputs.registryName.value -t "$($image.name):$($state.tag)" -f $image.file . --no-logs -o none
        }
    } finally { Pop-Location }
    $state | Add-Member -NotePropertyName operationsTag -NotePropertyValue $state.tag -Force
    $state | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $statePath -Encoding utf8
}
Assert-PublishedImages $state
if ($BuildImagesOnly) { Write-Host "Published images: $($state.tag)"; return }
if (@($state.applicationUsers).Count -eq 0) {
    Write-Warning 'No application users configured. Provision SenderObjectIds/ReceiverObjectIds before browser document access.'
}
Initialize-Kubernetes $state
Invoke-Kubectl annotate service aks-istio-ingressgateway-external -n aks-istio-ingress `
    "service.beta.kubernetes.io/azure-pip-name=$($state.outputs.publicIpName.value)" `
    "service.beta.kubernetes.io/azure-load-balancer-resource-group=$ResourceGroupName" --overwrite

Apply-Object @{ apiVersion = 'v1'; kind = 'Namespace'; metadata = @{ name = 'obo-operations' } }
$identities = @(@{ name = 'operations'; clientId = $state.outputs.operationsClientId.value })
foreach ($identity in $identities) {
    Apply-Object @{
        apiVersion = 'v1'; kind = 'ServiceAccount'
        metadata = @{
            name = $identity.name; namespace = 'obo-operations'
            annotations = @{ 'azure.workload.identity/client-id' = $identity.clientId; 'azure.workload.identity/tenant-id' = $TenantId.ToString() }
        }
    }
}
Start-AdministrativeOperation -Mode 'bootstrap' -State $state

$values = @{
    TENANT_ID = $TenantId.ToString(); API_CLIENT_ID = $state.api.appId; BFF_CLIENT_ID = $state.bff.appId
    ISTIO_REVISION = $state.istioRevision; PUBLIC_HOST = $state.outputs.publicHost.value
    BLOB_URL = $state.outputs.blobContainerUrl.value; SQL_FQDN = $state.outputs.sqlFqdn.value
    DATABASE = $state.outputs.databaseName.value; REGISTRY = $state.outputs.registryHost.value; TAG = $state.tag
}
Invoke-Kubectl apply -f (Render-Manifest 'apps' $values)
Apply-Object @{
    apiVersion = 'v1'; kind = 'ConfigMap'; metadata = @{ name = 'obo-acme-hook'; namespace = 'aks-istio-ingress' }
    data = @{ 'certificate.py' = (Get-Content -LiteralPath (Join-Path $repo 'infra\kubernetes\certificate.py') -Raw).Replace("`r`n", "`n") }
}
Initialize-IngressTlsSecret
Invoke-Kubectl apply -f (Render-Manifest 'ingress' $values)
Invoke-Kubectl rollout status deployment/bff -n obo --timeout=300s
Invoke-Kubectl rollout status deployment/api -n obo --timeout=300s
$certificateJob = "obo-acme-initial-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
Invoke-Kubectl create job $certificateJob --from=cronjob/obo-acme -n aks-istio-ingress
Wait-Job 'aks-istio-ingress' $certificateJob
$url = "https://$($state.outputs.publicHost.value)"
$health = Invoke-RestMethod "$url/healthz"
if ($health.status -ne 'ok') { throw 'Public BFF health check failed.' }
Write-Host "Published: $url"
Write-Host "State: $statePath"
Write-Host "Resource group: https://portal.azure.com/#resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/overview"
