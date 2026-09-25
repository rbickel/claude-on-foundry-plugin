<#
.SYNOPSIS
  Return an Entra ID access token for Claude Code's APIM gateway.

.DESCRIPTION
  Intended for Claude Code's `apiKeyHelper` setting. Writes ONLY the access token
  to stdout; diagnostics go to stderr via thrown errors. Anything else printed to
  stdout would be sent as the credential and produce a 401.

  Claude Code invokes this on a refresh interval and uses the output as the
  bearer credential, which is what APIM's <validate-azure-ad-token> reads from
  the Authorization header.

  Reads two environment variables, set in the same settings.json `env` block:
    CLAUDE_GATEWAY_SCOPE      api://<GATEWAY_APP_ID>/access_as_user
    CLAUDE_GATEWAY_TENANT_ID  expected tenant, guards against a wrong az login

.NOTES
  Requires the Azure CLI, signed in (`az login`).
  Install to %USERPROFILE%\.claude\Get-GatewayAccessToken.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$scope            = $env:CLAUDE_GATEWAY_SCOPE
$expectedTenantId = $env:CLAUDE_GATEWAY_TENANT_ID

if ([string]::IsNullOrWhiteSpace($scope)) {
    throw 'CLAUDE_GATEWAY_SCOPE is not configured.'
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) was not found on PATH.'
}

$currentTenantId = az account show `
    --query tenantId `
    --output tsv `
    --only-show-errors
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentTenantId)) {
    throw 'Azure CLI is not signed in. Run az login before starting Claude Code.'
}

if (
    -not [string]::IsNullOrWhiteSpace($expectedTenantId) -and
    $currentTenantId.Trim() -ne $expectedTenantId.Trim()
) {
    throw "Azure CLI is signed in to tenant '$($currentTenantId.Trim())', not '$($expectedTenantId.Trim())'."
}

$token = az account get-access-token `
    --scope $scope `
    --query accessToken `
    --output tsv `
    --only-show-errors
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    throw "Unable to acquire an access token for scope '$scope'."
}

[Console]::Out.Write($token.Trim())
