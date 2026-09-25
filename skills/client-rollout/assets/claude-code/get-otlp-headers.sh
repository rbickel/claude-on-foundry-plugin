#!/usr/bin/env bash
# Return the HTTP headers Claude Code should send when exporting OpenTelemetry to
# the APIM OTLP ingestion API.
#
# For Claude Code's `otelHeadersHelper` setting. NOTE the contract differs from
# `apiKeyHelper`: this script must print a JSON OBJECT of header name/value pairs,
# not a bare token.
#
# settings.json:
#   "otelHeadersHelper": "$HOME/.claude/get-otlp-headers.sh"
#
# Install:
#   cp get-otlp-headers.sh ~/.claude/
#   chmod +x ~/.claude/get-otlp-headers.sh
#
# Claude Code re-runs this at startup and every 29 minutes
# (CLAUDE_CODE_OTEL_HEADERS_HELPER_DEBOUNCE_MS, default 1740000), which is what
# makes a short-lived Entra token workable for telemetry export.
#
# Only used with the http/protobuf and http/json protocols. With grpc, Claude Code
# reads the static OTEL_EXPORTER_OTLP_HEADERS variable instead.
#
# If this script fails, telemetry export stops for the remainder of the session.
# The failure is reported in /status, the debug log, and on stderr for -p runs.
#
# Requires the Azure CLI, signed in (az login).

set -euo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }

[[ -n "${CLAUDE_GATEWAY_SCOPE:-}" ]] || die 'CLAUDE_GATEWAY_SCOPE is not configured.'
command -v az >/dev/null 2>&1 || die 'Azure CLI (az) was not found on PATH.'

current_tenant="$(az account show --query tenantId -o tsv --only-show-errors 2>/dev/null)" \
  || die 'Azure CLI is not signed in. Run az login before starting Claude Code.'
[[ -n "$current_tenant" ]] \
  || die 'Azure CLI is not signed in. Run az login before starting Claude Code.'

if [[ -n "${CLAUDE_GATEWAY_TENANT_ID:-}" && "$current_tenant" != "$CLAUDE_GATEWAY_TENANT_ID" ]]; then
  die "Azure CLI is signed in to tenant '$current_tenant', not '$CLAUDE_GATEWAY_TENANT_ID'."
fi

token="$(az account get-access-token \
  --scope "$CLAUDE_GATEWAY_SCOPE" \
  --query accessToken -o tsv --only-show-errors 2>/dev/null)" \
  || die "Unable to acquire an access token for scope '$CLAUDE_GATEWAY_SCOPE'."

[[ -n "$token" ]] || die "Unable to acquire an access token for scope '$CLAUDE_GATEWAY_SCOPE'."

# If the OTLP API requires an APIM subscription key instead of (or in addition to)
# an Entra token, add it here -- read from the environment, never hardcoded:
#
#   printf '{"Authorization": "Bearer %s", "Ocp-Apim-Subscription-Key": "%s"}' \
#     "$token" "${CLAUDE_OTLP_SUBSCRIPTION_KEY:?}"

printf '{"Authorization": "Bearer %s"}' "$token"
