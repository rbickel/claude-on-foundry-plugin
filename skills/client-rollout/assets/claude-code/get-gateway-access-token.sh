#!/usr/bin/env bash
# Return an Entra ID access token for Claude Code's APIM gateway.
#
# macOS / Linux equivalent of Get-GatewayAccessToken.ps1, for Claude Code's
# `apiKeyHelper` setting. Writes ONLY the token to stdout; anything else on
# stdout becomes the credential and produces a 401.
#
# settings.json:
#   "apiKeyHelper": "$HOME/.claude/get-gateway-access-token.sh"
#
# Install:
#   cp get-gateway-access-token.sh ~/.claude/
#   chmod +x ~/.claude/get-gateway-access-token.sh
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

printf '%s' "$token"
