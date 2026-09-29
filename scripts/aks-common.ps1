Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\azure-common.ps1"

function Invoke-Kubectl {
    $result = & kubectl --kubeconfig $script:KubeConfig @args
    if ($LASTEXITCODE -ne 0) { throw "kubectl failed (exit $LASTEXITCODE). See the error above." }
    return $result
}

function Apply-Object($Object) {
    $Object | ConvertTo-Json -Depth 40 -Compress | & kubectl --kubeconfig $script:KubeConfig apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Kubernetes object apply failed.' }
}

function Invoke-GraphPatch([string] $Uri, $Body) {
    $path = Join-Path $script:OutputDirectory "graph-$([guid]::NewGuid().ToString('N')).local.json"
    try {
        $Body | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8
        Invoke-Az rest --method PATCH --url $Uri --headers 'Content-Type=application/json' --body "@$path" -o none
    } finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
}

function Render-Manifest([string] $Name, [hashtable] $Values) {
    $path = Join-Path $PSScriptRoot "..\infra\kubernetes\$Name.yaml.example"
    $content = Get-Content -LiteralPath $path -Raw
    foreach ($key in $Values.Keys) { $content = $content.Replace("__$($key)__", [string]$Values[$key]) }
    if ($content.Contains('__MANIFEST_SHA256__')) {
        # Hash before inserting the revision; normalize line endings across Windows/Linux publishers.
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($content.Replace("`r`n", "`n"))
            $revision = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
        $content = $content.Replace('__MANIFEST_SHA256__', $revision)
    }
    if ($content -cmatch '__[A-Z_]+__') { throw "Unresolved manifest placeholder: $($Matches[0])" }
    $output = Join-Path $script:OutputDirectory "$Name.local.yaml"
    $content | Set-Content -LiteralPath $output -Encoding utf8
    return $output
}

function Initialize-IngressTlsSecret {
    $json = Invoke-Kubectl get secret obo-tls -n aks-istio-ingress --ignore-not-found -o json
    if (-not [string]::IsNullOrWhiteSpace(($json -join "`n"))) {
        $secret = ($json -join "`n") | ConvertFrom-Json
        if ($secret.type -eq 'kubernetes.io/tls') { return }
        $data = $secret.PSObject.Properties['data']
        if ($secret.type -ne 'Opaque' -or
            ($null -ne $data -and $null -ne $data.Value -and @($data.Value.PSObject.Properties).Count -gt 0)) {
            throw 'obo-tls has an unexpected type or contains data. Refusing to replace it.'
        }
        # Kubernetes Secret type is immutable; only the empty legacy placeholder can be replaced.
        Write-Host 'Replacing the empty Opaque TLS placeholder with a kubernetes.io/tls Secret.'
        Invoke-Kubectl delete secret obo-tls -n aks-istio-ingress --wait=true | Out-Null
    }
    Apply-Object @{
        apiVersion = 'v1'; kind = 'Secret'; metadata = @{ name = 'obo-tls'; namespace = 'aks-istio-ingress' }
        type = 'kubernetes.io/tls'; data = @{ 'tls.crt' = ''; 'tls.key' = '' }
    } | Out-Null
}

function New-DeploymentState(
    [string] $SubscriptionId, [string] $TenantId, [string] $ResourceGroupName,
    $Api, $Bff, $Outputs, [string] $IstioRevision,
    [string] $SqlAdminObjectId, [array] $ApplicationUsers, $PreviousState = $null
) {
    $state = @{
        subscriptionId = $SubscriptionId; tenantId = $TenantId; resourceGroup = $ResourceGroupName
        api = $Api; bff = $Bff; outputs = $Outputs; istioRevision = $IstioRevision
        sqlAdminObjectId = $SqlAdminObjectId; applicationUsers = @($ApplicationUsers)
        tag = $null; operationsTag = $null; infrastructureReady = $false
    }
    if ($null -ne $PreviousState) {
        if ($PreviousState.subscriptionId -ne $SubscriptionId -or $PreviousState.tenantId -ne $TenantId -or
            $PreviousState.resourceGroup -ne $ResourceGroupName) { throw 'Previous deployment state belongs to another target.' }
        if ($PreviousState.outputs.registryHost.value -eq $Outputs.registryHost.value) {
            $state.tag = $PreviousState.tag
            $state.operationsTag = if ($PreviousState.PSObject.Properties['operationsTag']) { $PreviousState.operationsTag } else { $PreviousState.tag }
        }
    }
    return $state
}

function Assert-PublishedImages($State) {
    foreach ($property in @('tag','operationsTag')) {
        if (-not $State.PSObject.Properties[$property] -or [string]::IsNullOrWhiteSpace($State.$property)) {
            throw 'No published image tags in deployment state. Run deploy-aks.ps1 without -SkipImageBuild first.'
        }
    }
}

function Wait-Job([string] $Namespace, [string] $Name, [int] $TimeoutSeconds = 600) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $job = Invoke-Kubectl get job $Name -n $Namespace -o json | ConvertFrom-Json
        $property = $job.status.PSObject.Properties['conditions']
        $conditions = if ($null -ne $property) { @($property.Value) } else { @() }
        if ($conditions | Where-Object { $_.type -eq 'Complete' -and $_.status -eq 'True' }) {
            Invoke-Kubectl logs -n $Namespace "job/$Name"
            return
        }
        if ($conditions | Where-Object { $_.type -eq 'Failed' -and $_.status -eq 'True' }) {
            Invoke-Kubectl logs -n $Namespace "job/$Name"
            throw "Job $Namespace/$Name failed."
        }
        Start-Sleep -Seconds 10
    }
    Invoke-Kubectl describe job $Name -n $Namespace
    throw "Job $Namespace/$Name timed out."
}

function Get-ValidationIdentities($Validation) {
    $expected = @('sender','reader','admin-with-key','admin-without-key')
    if ($null -eq $Validation -or @($Validation.identities).Count -ne $expected.Count) {
        throw 'Optional validation identities are missing. Run setup-validation.ps1 first.'
    }
    foreach ($actor in $expected) {
        $matches = @($Validation.identities | Where-Object actor -eq $actor)
        if ($matches.Count -ne 1 -or [guid]$matches[0].clientId -eq [guid]::Empty -or [guid]$matches[0].objectId -eq [guid]::Empty) {
            throw "Invalid validation identity for $actor."
        }
    }
    return $Validation.identities
}

function Start-Operation(
    [ValidateSet('bootstrap','setup-validation','remove-validation','sender','reader','admin-with-key','admin-without-key')]
    [string] $Mode, $State, [string] $DocumentId = '', $Validation = $null
) {
    $administrative = $Mode -in @('bootstrap','setup-validation','remove-validation')
    $testIdentities = if ($Mode -eq 'bootstrap') { @() } else { @(Get-ValidationIdentities $Validation) }
    $jobName = "obo-$Mode-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    $account = if ($administrative) { 'operations' } else { "test-$Mode" }
    $environment = @(
        @{ name = 'SQL_FQDN'; value = $State.outputs.sqlFqdn.value },
        @{ name = 'DATABASE'; value = $State.outputs.databaseName.value },
        @{ name = 'BLOB_URL'; value = $State.outputs.blobContainerUrl.value },
        @{ name = 'KEY_URL'; value = $State.outputs.keyVaultKeyUrl.value }
    )
    if ($Mode -eq 'bootstrap') {
        $environment += @{ name = 'APPLICATION_USERS'; value = (ConvertTo-Json -InputObject @($State.applicationUsers) -Compress -Depth 5) }
        $environment += @{ name = 'SQL_ADMIN_OBJECT_ID'; value = $State.sqlAdminObjectId }
    }
    foreach ($identity in $testIdentities) {
        $environment += @{ name = "TEST_$($identity.actor.Replace('-','_').ToUpperInvariant())_OID"; value = $identity.objectId }
        $environment += @{ name = "TEST_$($identity.actor.Replace('-','_').ToUpperInvariant())_CLIENT_ID"; value = $identity.clientId }
    }
    if ($DocumentId) { $environment += @{ name = 'TEST_DOCUMENT_ID'; value = $DocumentId } }
    $operationsTag = if ($State.PSObject.Properties['operationsTag']) { $State.operationsTag } else { $State.tag }
    if ([string]::IsNullOrWhiteSpace($operationsTag)) { throw 'Operations image tag is required.' }
    $container = @{
        name = 'operations'
        image = "$($State.outputs.registryHost.value)/obo-operations:$operationsTag"
        args = @($Mode)
        env = $environment
        securityContext = @{ allowPrivilegeEscalation = $false; capabilities = @{ drop = @('ALL') } }
        resources = @{ requests = @{ cpu = '100m'; memory = '256Mi' }; limits = @{ cpu = '1'; memory = '512Mi' } }
    }
    $spec = @{
        serviceAccountName = $account
        restartPolicy = 'Never'
        automountServiceAccountToken = $false
        securityContext = @{ runAsNonRoot = $true; runAsUser = 1654; fsGroup = 1654; seccompProfile = @{ type = 'RuntimeDefault' } }
        containers = @($container)
    }
    if ($administrative) {
        $container.volumeMounts = @(@{ name = 'bootstrap'; mountPath = '/bootstrap'; readOnly = $true })
        $spec.volumes = @(@{ name = 'bootstrap'; secret = @{ secretName = 'bootstrap-sql' } })
    }
    Apply-Object @{
        apiVersion = 'batch/v1'; kind = 'Job'
        metadata = @{
            name = $jobName; namespace = 'obo-operations'
            labels = @{ 'app.kubernetes.io/component' = $(if ($Mode -eq 'bootstrap') { 'bootstrap' } else { 'validation' }) }
        }
        spec = @{
            backoffLimit = 0; activeDeadlineSeconds = 600; ttlSecondsAfterFinished = 3600
            template = @{
                metadata = @{ labels = @{ 'azure.workload.identity/use' = 'true' }; annotations = @{ 'sidecar.istio.io/inject' = 'false' } }
                spec = $spec
            }
        }
    }
    try { Wait-Job 'obo-operations' $jobName }
    finally {
        if ($administrative) { Invoke-Kubectl delete job $jobName -n obo-operations --ignore-not-found | Out-Null }
    }
}

function Initialize-Kubernetes($State) {
    Get-Command kubectl,kubelogin -ErrorAction Stop | Out-Null
    Invoke-Az aks get-credentials -g $State.resourceGroup -n $State.outputs.clusterName.value --file $script:KubeConfig --overwrite-existing
    & kubelogin convert-kubeconfig --login azurecli --kubeconfig $script:KubeConfig
    if ($LASTEXITCODE -ne 0) { throw 'kubelogin failed.' }
    Invoke-Kubectl get nodes
}

function Start-AdministrativeOperation([string] $Mode, $State, $Validation = $null) {
    if ($Mode -notin @('bootstrap','setup-validation','remove-validation')) { throw 'Unknown administrative operation.' }
    $sqlToken = Invoke-Az account get-access-token --resource 'https://database.windows.net' --query accessToken -o tsv
    if ([string]::IsNullOrWhiteSpace($sqlToken)) { throw 'SQL administrator token acquisition returned no token.' }
    try {
        Apply-Object @{
            apiVersion = 'v1'; kind = 'Secret'; metadata = @{ name = 'bootstrap-sql'; namespace = 'obo-operations' }
            type = 'Opaque'; stringData = @{ 'access-token' = $sqlToken }
        } | Out-Null
        Start-Operation -Mode $Mode -State $State -Validation $Validation
    } finally {
        $sqlToken = $null
        Invoke-Kubectl delete secret bootstrap-sql -n obo-operations --ignore-not-found | Out-Null
    }
}
