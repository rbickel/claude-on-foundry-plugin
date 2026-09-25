---
name: client-rollout
description: Generate and validate the Claude Code CLI and Claude Desktop configuration that points users at the Azure AI Gateway — settings.json with an Entra token helper, the Claude Desktop OIDC gateway config, and a verification procedure. Use when the user says "configure the clients", "point Claude Code at my gateway", "set up Claude Desktop for Foundry", "roll this out to users", "generate managed settings", or reports 401/403 errors from the gateway. Emits config files for review; does not modify user machines.
---

# Claude client rollout

Produce the client-side configuration that routes Claude Code and Claude Desktop
through the APIM gateway, and a procedure to prove it works.

Write artifacts to `./migration/clients/`. Do not overwrite a user's live
`~/.claude/settings.json` without explicit confirmation — read it first, show the diff,
and let them decide.

## How authentication flows

Both clients send an **Entra ID access token as a bearer credential**. APIM's
`validate-azure-ad-token` reads the `Authorization` header, checks tenant and
audience, and parks the decoded token for the quota policy.

The two clients obtain that token differently:

| | Claude Code CLI | Claude Desktop |
| --- | --- | --- |
| Mechanism | `apiKeyHelper` script → `az account get-access-token` | built-in interactive browser OIDC |
| Prerequisite | Azure CLI installed and `az login` done | none beyond a browser |
| Config key | `apiKeyHelper` + `env.ANTHROPIC_BASE_URL` | `inference.provider: "gateway"` |
| Refresh | Claude Code re-invokes the helper | refresh token (`offline_access`) |

Claude Code's dependency on `az login` is the main rollout friction: the token is only
as available as the user's Azure CLI session. If a user reports sudden 401s, check
`az account show` first.

## Steps

### 1. Claude Code

Start from `${CLAUDE_PLUGIN_ROOT}/skills/client-rollout/assets/claude-code/settings.template.json`
and substitute `<APIM_NAME>`, `<GATEWAY_APP_ID>`, `<TENANT_ID>`, `<MODEL_ID>` from the
migration profile.

Ship the matching token helper:

- Windows → `assets/claude-code/Get-GatewayAccessToken.ps1` → `%USERPROFILE%\.claude\`
- macOS/Linux → `assets/claude-code/get-gateway-access-token.sh` → `~/.claude/` (`chmod +x`)

If telemetry is also going through the gateway (see the `otel-telemetry` skill), ship
the OTLP header helper alongside it:

- Windows → `assets/claude-code/Get-OtlpHeaders.ps1`
- macOS/Linux → `assets/claude-code/get-otlp-headers.sh` (`chmod +x`)

These use the same Entra scope as the token helper, so telemetry needs no APIM
subscription key on developer machines. **The output contract differs:**
`apiKeyHelper` prints a bare token, `otelHeadersHelper` prints a JSON object of
headers. Swapping them produces a helper that "runs fine" and exports nothing.

Choose a deployment scope with the user:

| Path | Effect |
| --- | --- |
| `C:\ProgramData\ClaudeCode\managed-settings.json` (Windows) | Enterprise policy — users cannot override |
| `/Library/Application Support/ClaudeCode/managed-settings.json` (macOS) | same |
| `/etc/claude-code/managed-settings.json` (Linux) | same |
| `~/.claude/settings.json` | per user — right for a pilot |

Recommend piloting with one user at `~/.claude/settings.json` before pushing managed
policy to a fleet. A broken managed-settings.json is hard for users to work around,
by design.

**Do not set `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` alongside `apiKeyHelper`.**
A static credential shadows the refreshing helper and works until the token expires,
which makes the failure look intermittent and unrelated.

### 2. Claude Desktop

Start from `assets/claude-desktop/gateway-config.template.json`.

Two values must agree with the app registration or sign-in fails:

- `oidc.issuer` — must match the token version.
  `requestedAccessTokenVersion: 2` → `https://login.microsoftonline.com/<TENANT_ID>/v2.0`.
  Version 1 → `https://sts.windows.net/<TENANT_ID>/`.
- `oidc.scopes` — must include `api://<GATEWAY_APP_ID>/access_as_user`, plus
  `offline_access` so the session survives token expiry.

The app registration needs a loopback redirect URI in `publicClient.redirectUris` for
the browser flow.

> **Confirm the config file path with the user.** This gateway config file is distinct
> from `claude_desktop_config.json`, which configures MCP servers only. Ask the user
> where their working Claude Desktop deployment reads this file from and record it in
> the migration profile under `clients.claudeDesktop.configPath` rather than assuming
> a path.

### 3. Verify

Work outward — identity, then gateway, then client. Each step isolates a different
failure.

```bash
# 1. Is the token obtainable at all?
az account show --query tenantId -o tsv
az account get-access-token --scope "api://<GATEWAY_APP_ID>/access_as_user" --query accessToken -o tsv

# 2. Does the token carry the claims the quota policy needs?
az account get-access-token --scope "api://<GATEWAY_APP_ID>/access_as_user" --query accessToken -o tsv \
  | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | python -m json.tool
#    check: aud, iss, sub present; groups contains the tier group object id
#    if you see _claim_names instead of groups, you have hit the groups-overage trap

# 3. Does the gateway accept it end to end?
TOKEN=$(az account get-access-token --scope "api://<GATEWAY_APP_ID>/access_as_user" --query accessToken -o tsv)
curl -sS -D- -o /dev/null -X POST "https://<APIM_NAME>.azure-api.net/claude/v1/messages" \
  -H "Authorization: Bearer $TOKEN" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"<MODEL_ID>","max_tokens":16,"messages":[{"role":"user","content":"ping"}]}'
#    expect 200 and an x-remaining-quota-tokens response header
```

Then the client itself: `claude --version`, start a session, and run `/status` to
confirm it reports the gateway base URL rather than api.anthropic.com.

## Diagnosing failures

| Symptom | Most likely cause |
| --- | --- |
| 401 at the gateway | Audience mismatch — token `aud` vs APIM `<audiences>`. Check `requestedAccessTokenVersion`. |
| 401 only after a while | A static `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN` is shadowing `apiKeyHelper`, or `az login` expired. |
| `403 No LLM quota assigned` | User is in no tier group, **or** the `llm-tier-*-group` named value holds an app role id instead of a group object id. |
| 403 for one senior user only | Groups overage — `_claim_names` replaced the `groups` claim. Switch to `ApplicationGroup`. |
| 429 | Quota exhausted for the period. Check the `x-remaining-quota-tokens` header. |
| Works in curl, fails in Claude Code | `apiKeyHelper` printing something extra to stdout, or not executable / wrong path. |
| Token counts and quotas read zero | `Accept-Encoding` is not being stripped at the gateway. |
| LLM works, no telemetry at all | `OTEL_EXPORTER_OTLP_PROTOCOL` unset — Claude Code has no default and fails silently. |
| Telemetry 404s | `:443` or a `/v1/<signal>` suffix on `OTEL_EXPORTER_OTLP_ENDPOINT`. The port lands after the path. |
| Telemetry 415s | Protocol is `http/json`; the OTLP ingestion API accepts protobuf only. |
| Telemetry stops mid-session | `otelHeadersHelper` failed — it re-runs every 29 min. Check `/status`. |

## Guardrails

- The helper scripts must print **only** the token to stdout.
- An agentic client can consume a very large quota in one session. Warn the user
  before setting a tight `Daily` quota on interactive developers.
- `OTEL_LOG_USER_PROMPTS` sends prompt text off the machine. Leave it off unless
  explicitly approved.
