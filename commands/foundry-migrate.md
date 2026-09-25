---
description: Run the Claude Enterprise → Anthropic on Foundry migration workflow, or jump to one stage of it
argument-hint: "[inventory|gateway|clients|telemetry|status]"
---

# Claude → Foundry migration

Stage requested: **$1** (empty means "work out where we are and continue").

## Current state

Migration artifacts present:

!`ls -R ./migration 2>/dev/null || echo "(no ./migration directory yet — nothing started)"`

Toolchain:

!`for c in az azd claude; do printf '%s: ' "$c"; command -v "$c" >/dev/null 2>&1 && echo present || echo MISSING; done`

Azure context:

!`az account show --query "{subscription:name,tenant:tenantId}" -o json 2>/dev/null || echo "(not signed in — run: az login)"`

## What to do

This plugin runs a four-stage migration. Each stage has a dedicated skill; invoke the
one that matches, and read its bundled `references/` before answering detailed
questions rather than working from memory.

| Stage | Skill | Produces |
| --- | --- | --- |
| 1. inventory | `enterprise-inventory` | `./migration/migration-profile.yaml` |
| 2. gateway | `gateway-blueprint` | `./migration/azure/` — policies, Entra template, named values, runbook |
| 3. clients | `client-rollout` | `./migration/clients/` — Claude Code + Desktop config |
| 4. telemetry | `otel-telemetry` | `./migration/telemetry/` — APIM OTLP API, backends, client env, queries |

Behaviour:

- If `$1` names a stage, go straight to that skill.
- If `$1` is `status`, summarise what exists in `./migration`, what is still
  placeholder (`<...>`), and what the next action is. Do not start work.
- If `$1` is empty, infer the next stage from what is already on disk and confirm with
  the user before proceeding.

Stages 2–4 depend on the migration profile from stage 1. If it is missing, say so and
offer to start there rather than inventing quota numbers.

## Rules for this workflow

**This iteration is read-only and emits artifacts only.** Discover with `list`/`show`
and `GET`; write files under `./migration/`. Do not create, update or delete anything
in Azure or in the customer's Anthropic organization, and do not modify a user's live
client configuration without showing a diff and getting explicit confirmation. If the
user asks you to deploy, tell them this iteration produces a runbook for a human to
execute.

Never write a secret — API key, admin key, client secret, connection string — into an
artifact. Reference secrets by name and keep them in APIM named values marked
`--secret true`, Key Vault, or Container Apps secrets.

Flag rather than silently resolve: spend limits that have no API and must be
transcribed by hand, tier groupings that need a human decision, per-user telemetry
dimensions that are personal data, and any placeholder you could not fill.
