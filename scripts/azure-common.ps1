function Initialize-AzureContext([string] $SubscriptionId, [string] $TenantId) {
    if ($SubscriptionId) {
        & az account set --subscription $SubscriptionId --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed (exit $LASTEXITCODE). Could not select the target subscription." }
    }
    $json = & az account show -o json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed (exit $LASTEXITCODE). Could not read the active context." }
    $account = $json | ConvertFrom-Json
    if (-not $account.id -or $account.state -ne 'Enabled') { throw 'An enabled Azure subscription is required.' }
    if ($SubscriptionId -and $account.id -ne $SubscriptionId) { throw 'Azure CLI selected a different subscription.' }
    if ($TenantId -and $account.tenantId -ne $TenantId) { throw 'Azure CLI context belongs to a different tenant.' }
    $script:SubscriptionId = $account.id
}

function Invoke-Az {
    if ($args[0] -eq 'ad') {
        $active = & az account show --query id -o tsv --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed (exit $LASTEXITCODE). Could not verify the directory context." }
        if ($active -ne $script:SubscriptionId) {
            throw 'Azure CLI context changed. Select the explicit target subscription before directory operations.'
        }
        $result = & az @args --only-show-errors
    } else {
        $result = & az @args --subscription $script:SubscriptionId --only-show-errors
    }
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed (exit $LASTEXITCODE). See the error above." }
    return $result
}

function Ensure-AzureRoleAssignment([string] $ObjectId, [string] $Role, [string] $Scope) {
    $assignments = @(Invoke-Az role assignment list --scope $Scope --role $Role --fill-principal-name false -o json | ConvertFrom-Json)
    if (-not ($assignments | Where-Object principalId -eq $ObjectId)) {
        Invoke-Az role assignment create --assignee-object-id $ObjectId --assignee-principal-type ServicePrincipal --role $Role --scope $Scope -o none
    }
}
