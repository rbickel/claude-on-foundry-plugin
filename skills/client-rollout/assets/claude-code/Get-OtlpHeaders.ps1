<#
    Return the HTTP headers Claude Code should send when exporting OpenTelemetry to
    the APIM OTLP ingestion API.

    For Claude Code's `otelHeadersHelper` setting. NOTE the contract differs from
    `apiKeyHelper`: this script must print a JSON OBJECT of header name/value pairs,
    not a bare token.

    settings.json:
      "otelHeadersHelper": "powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\\.claude\\Get-OtlpHeaders.ps1"

    Install:
      Copy-Item Get-OtlpHeaders.ps1 "$env:USERPROFILE\.claude\"

    Claude Code re-runs this at startup and every 29 minutes
    (CLAUDE_CODE_OTEL_HEADERS_HELPER_DEBOUNCE_MS, default 1740000), which is what
    makes a short-lived Entra token workable for telemetry export.

    Only used with the http/protobuf and http/json protocols. With grpc, Claude Code
    reads the static OTEL_EXPORTER_OTLP_HEADERS variable instead.

    If this script fails, telemetry export stops for the remainder of the session.
    The failure is reported in /status, the debug log, and on stderr for -p runs.

    Requires the Azure CLI, signed in (az login).
#>

$ErrorActionPreference = 'Stop'

if (-not $env:CLAUDE_GATEWAY_SCOPE) {
    Write-Error 'CLAUDE_GATEWAY_SCOPE is not configured.'
    exit 1
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error 'Azure CLI (az) was not found on PATH.'
    exit 1
}

$currentTenant = az account show --query tenantId -o tsv --only-show-errors 2>$null
if (-not $currentTenant) {
    Write-Error 'Azure CLI is not signed in. Run az login before starting Claude Code.'
    exit 1
}

if ($env:CLAUDE_GATEWAY_TENANT_ID -and $currentTenant -ne $env:CLAUDE_GATEWAY_TENANT_ID) {
    Write-Error "Azure CLI is signed in to tenant '$currentTenant', not '$env:CLAUDE_GATEWAY_TENANT_ID'."
    exit 1
}

$token = az account get-access-token `
    --scope $env:CLAUDE_GATEWAY_SCOPE `
    --query accessToken -o tsv --only-show-errors 2>$null

if (-not $token) {
    Write-Error "Unable to acquire an access token for scope '$env:CLAUDE_GATEWAY_SCOPE'."
    exit 1
}

# If the OTLP API requires an APIM subscription key instead of (or in addition to)
# an Entra token, add it here -- read from the environment, never hardcoded:
#
#   $headers = @{
#       'Authorization'            = "Bearer $token"
#       'Ocp-Apim-Subscription-Key' = $env:CLAUDE_OTLP_SUBSCRIPTION_KEY
#   }

$headers = @{ 'Authorization' = "Bearer $token" }

# -Compress keeps the output a single line. Write-Output adds no trailing newline
# issues that would corrupt the JSON contract.
$headers | ConvertTo-Json -Compress
