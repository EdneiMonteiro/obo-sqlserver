param(
    [Parameter(Mandatory = $true)]
    [string] $BaseUrl,

    [Parameter(Mandatory = $false)]
    [string] $SenderToken,

    [Parameter(Mandatory = $false)]
    [string] $ReceiverToken,

    [Parameter(Mandatory = $false)]
    [string] $UnauthorizedToken
)

$ErrorActionPreference = "Stop"

Write-Host "Health check..."
Invoke-RestMethod -Method Get -Uri "$BaseUrl/healthz" | Format-List

if (-not $SenderToken -or -not $ReceiverToken -or -not $UnauthorizedToken) {
    Write-Warning "Provide SenderToken, ReceiverToken and UnauthorizedToken to run end-to-end validation."
    return
}

Write-Host "Token-based validation is intentionally left explicit because tokens must not be persisted in files or logs."
Write-Host "Use POST /documents with sender token, GET /documents/{id} with receiver token, then repeat GET with unauthorized token expecting 403."

