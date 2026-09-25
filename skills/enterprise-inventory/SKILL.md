---
name: enterprise-inventory
description: Extract the current Claude Enterprise / Claude Console organization configuration — workspaces, members and roles, rate limits, spend limits and usage baselines — into a reviewable migration profile that later drives the Azure gateway design. Use when the user says "extract my Claude Enterprise config", "inventory my workspaces", "what are my current quotas", "capture a usage baseline", or is starting a migration to Anthropic on Foundry. Read-only against Anthropic's Admin API.
---

# Claude Enterprise inventory

Capture what the organization looks like today, so the Azure gateway can reproduce it.
Output is a single reviewable file: `./migration/migration-profile.yaml`.

**Read-only.** Use only `GET` requests. Never create, update or archive anything in the
customer's Anthropic organization.

## Before you start: capture the baseline first

State this to the user plainly, because the ordering is irreversible:

> Claude Code usage that is routed through Microsoft Foundry, Bedrock or Vertex does
> **not** appear in Anthropic's Claude Code Analytics API. Once you cut over to the
> Foundry gateway, your Anthropic-side usage history stops accruing. Capture the usage
> and cost baseline **before** cutover, or you lose the ability to size Azure quotas
> against real consumption.

After cutover, the equivalent telemetry comes from APIM's `llm-emit-token-metric` and
the OpenTelemetry pipeline — see the `otel-telemetry` skill.

## Credentials

```bash
export ANTHROPIC_ADMIN_KEY="sk-ant-admin01-..."
```

Admin API keys are created by an organization Owner or Admin in the Claude Console;
they cannot be minted through the API. A key scoped to a single workspace is rejected
by these endpoints.

Every request needs:

```
x-api-key: $ANTHROPIC_ADMIN_KEY
anthropic-version: 2023-06-01
```

Validate the credential before doing anything else — it is the cheapest possible call:

```bash
curl -s https://api.anthropic.com/v1/organizations/me \
  -H "x-api-key: $ANTHROPIC_ADMIN_KEY" \
  -H "anthropic-version: 2023-06-01"
```

If this 401s, stop and ask the user for a correct admin key rather than guessing at
alternatives.

## Steps

### 1. Determine which product you are migrating

The two surfaces differ, and it changes which endpoints exist. Ask the user, or infer
from what responds:

| | Claude Console (API org) | Claude Enterprise (claude.ai) |
| --- | --- | --- |
| Workspaces | yes | no |
| API keys | yes | no |
| Rate limits API | yes | no |
| Usage / cost | `/v1/organizations/usage_report/*`, `/cost_report` | separate Analytics API under `/v1/organizations/analytics/`, needs its own Analytics API key |
| Members / invites | yes | yes |
| RBAC groups, per-member spend limits | no | yes |

Do not assume. If a workspaces call returns empty or 404, say so and adjust rather
than reporting "no workspaces configured".

### 2. Pull the inventory

See `references/admin-api.md` for the full endpoint list, exact response fields, and
both pagination models. In outline:

```bash
AUTH=(-H "x-api-key: $ANTHROPIC_ADMIN_KEY" -H "anthropic-version: 2023-06-01")
B=https://api.anthropic.com/v1/organizations

curl -s "$B/me"                                    "${AUTH[@]}"
curl -s "$B/users?limit=100"                       "${AUTH[@]}"
curl -s "$B/workspaces?limit=100&include_archived=false" "${AUTH[@]}"
curl -s "$B/workspaces/<WORKSPACE_ID>/members?limit=100"  "${AUTH[@]}"
curl -s "$B/api_keys?limit=100"                    "${AUTH[@]}"
curl -s "$B/rate_limits"                           "${AUTH[@]}"
curl -s "$B/workspaces/<WORKSPACE_ID>/rate_limits" "${AUTH[@]}"
```

Paginate to completion. List endpoints use an ID cursor (`before_id` / `after_id` /
`limit`, responding with `has_more` / `first_id` / `last_id`); report endpoints use an
opaque cursor (`limit` / `page`, responding with `has_more` / `next_page`). Silently
truncating at the first page produces a migration profile that under-provisions Azure.

### 3. Capture the usage baseline

```bash
curl -s "$B/usage_report/messages?starting_at=<ISO8601>&ending_at=<ISO8601>&bucket_width=1d&group_by[]=workspace_id&group_by[]=model" "${AUTH[@]}"
curl -s "$B/cost_report?starting_at=<ISO8601>&ending_at=<ISO8601>&bucket_width=1d"  "${AUTH[@]}"
```

Default to the last 30–90 days. You need peak daily tokens per workspace, not just the
mean — Azure quotas are enforced per period, so a mean-sized quota throttles the busy
days. Record both.

### 4. Record what the API cannot give you

This matters and must not be silently skipped:

- **Spend limits are not readable through any API.** Neither org-level nor
  per-workspace. They live in the Console UI under Settings → Workspaces → Spend
  limits, and Settings → Billing.
- **Rate limits are readable but not writable**, so they are a source for the profile,
  never a target.

Prompt the user to read the spend limits out of the Console and supply them. Put them
in the profile marked `source: manual` so a reviewer can tell which numbers were
observed and which were transcribed.

### 5. Write the migration profile

Fill in `${CLAUDE_PLUGIN_ROOT}/skills/enterprise-inventory/assets/migration-profile.template.yaml`
and write it to `./migration/migration-profile.yaml`.

Propose a tier mapping but do not decide it alone: several workspaces with similar
quotas usually collapse into one Entra group, and the user should confirm that
grouping. Each distinct tier becomes one Entra security group and one
`llm-tier-<name>-group` / `llm-tier-<name>-quota` named-value pair in the gateway.

Hand off to the `gateway-blueprint` skill.

## Guardrails

- Never write an API key, admin key or `secretText` into the profile. Record key
  **names** and IDs only.
- Member lists are personal data. Ask before writing names and email addresses to
  disk, and offer a count-only summary as the default.
- If a workspace has no usage in the baseline window, flag it rather than assigning it
  a zero quota — it may be seasonal, and a zero quota is a hard 403 for its users.
