# claude-on-foundry

A Claude Code plugin that helps Claude Enterprise customers migrate onto **Anthropic
models in Azure AI Foundry**, fronted by **Azure API Management** as an AI gateway
with Entra ID group-based token quotas, metrics and OpenTelemetry.

It inventories what you have, designs the Azure equivalent, and emits reviewable
artifacts — policies, an Entra app registration template, client configuration and a
runbook.

> **Iteration 1 is read-only.** The plugin inspects Azure, Entra ID and the Anthropic
> Admin API with `list` / `show` / `GET` calls, and writes files under `./migration/`.
> It does not create, update or delete cloud resources. Applying the runbook is a
> deliberate human step.

## Architecture

```text
Claude Code CLI ─┐   apiKeyHelper → az account get-access-token
                 ├─► APIM  https://<apim>.azure-api.net/claude/v1/messages
Claude Desktop ──┘   interactive browser OIDC
                          │
                          │  validate-azure-ad-token   Entra JWT, audience api://<app-id>
                          │  llm-token-limit           per-user quota, tier from `groups` claim
                          │  llm-emit-token-metric     → Application Insights
                          ▼
                 Azure AI Foundry
                 https://<resource>.services.ai.azure.com/anthropic
```

Azure AI Foundry exposes a **native Anthropic Messages API** under the `/anthropic`
path, so APIM is a plain pass-through — no request or response rewriting — and both
Claude clients speak their normal wire protocol to it.

Client telemetry takes the same shape. Application Insights accepts OTLP directly, so
APIM fronts it as a second API and there is **no OpenTelemetry Collector to deploy**:

```text
Claude Code ──OTLP/http-protobuf──► APIM  /<ai-name>/otlp/v1/{traces,metrics,logs}
                                      │   managed identity → monitor.azure.com
                                      ▼
                            Application Insights
                            ├─ traces + logs → Log Analytics  (KQL)
                            └─ metrics       → Azure Monitor Workspace (PromQL)
```

## Install

```text
/plugin marketplace add rbickel/claude-on-foundry-plugin
/plugin install claude-on-foundry@claude-on-foundry
```

## Use

```text
/foundry-migrate            # figure out where you are and continue
/foundry-migrate status     # what exists, what is still placeholder
/foundry-migrate inventory  # jump to a stage
```

Or just describe the task — the skills are triggered by intent, e.g. "extract my
Claude Enterprise config", "generate the APIM policies", "point Claude Code at my
gateway", "I lost my usage dashboards after migrating".

## The four stages

| Stage | Skill | Produces |
| --- | --- | --- |
| 1 | `enterprise-inventory` | `migration/migration-profile.yaml` — workspaces, members, rate limits, usage baseline, proposed tier mapping |
| 2 | `gateway-blueprint` | `migration/azure/` — APIM policies, policy fragment, Entra app registration template, named values, runbook |
| 3 | `client-rollout` | `migration/clients/` — Claude Code `settings.json` + token helper, Claude Desktop gateway config, verification procedure |
| 4 | `otel-telemetry` | `migration/telemetry/` — APIM OTLP ingestion API, backends, client env vars, KQL + PromQL queries |

## Requirements

- Claude Code
- Azure CLI (`az`), signed in to the target tenant
- An Anthropic **Admin API key** for stage 1 (`sk-ant-admin01-…`)
- Entra ID **P1 or P2** — required to assign security groups to app roles
- An APIM SKU supporting the GenAI policies and managed identity (Basic v2 verified;
  Consumption lacks managed identity)

## Things this plugin will tell you that are easy to get wrong

These are the failure modes the skills actively check for, because each one fails
silently or misleadingly:

- **`llm-tier-*-group` named values must hold Entra *security group object IDs*, not
  app role IDs.** An app role's GUID never appears in a token. Getting this wrong
  gives every user `403 No LLM quota assigned`.
- **`groupMembershipClaims` must be `ApplicationGroup`.** With `SecurityGroup` or
  `All`, a user in >200 groups loses the `groups` claim entirely to a `_claim_names`
  pointer — so your most senior people get locked out, seemingly at random.
- **`Accept-Encoding` must be stripped at the gateway.** A compressed response body
  cannot be parsed for token counts, so quotas and metrics silently read zero.
- **`llm-emit-token-metric` needs an Application Insights logger on the API.** Without
  one it computes metrics and discards them, with no error anywhere.
- **`preserveContent: true`** in the model-extraction fragment — without it the
  buffered request body is consumed and the backend receives an empty request.
- **Capture your Anthropic usage baseline *before* cutover.** Claude Code usage routed
  through Foundry is excluded from Anthropic's analytics, and the history cannot be
  reconstructed afterwards.
- **Don't set `ANTHROPIC_API_KEY` alongside `apiKeyHelper`** — the static value
  shadows the refreshing helper and fails only once the token expires.
- **Claude Code has no default OTLP protocol.** Leave `OTEL_EXPORTER_OTLP_PROTOCOL`
  unset and telemetry silently never exports — there is no error and no warning.
- **Client metrics are not in `customMetrics`.** OTLP metrics land in an Azure Monitor
  Workspace and are queried with PromQL; traces and logs land in Log Analytics
  (`OTelLogs`, `OTelSpans`) and are queried with KQL. One KQL query cannot cover both.
- **The OTLP metrics backend differs from the other two** — a `.metrics.ingest.` host
  rather than `.ingest.`, and the stream is `Microsoft-OtelMetrics`, breaking the
  `Microsoft-OTLP-*` pattern of traces and logs.
- **The APIM identity needs `Monitoring Metrics Publisher` on the *managed* DCR**,
  which lives in an auto-created `ai_<name>_<guid>_managed` resource group, not
  alongside your Application Insights component.

## Repository layout

```text
.claude-plugin/
  plugin.json                 plugin manifest
  marketplace.json            single-plugin marketplace, so this repo is installable directly
commands/
  foundry-migrate.md          /foundry-migrate orchestrator
skills/
  enterprise-inventory/       stage 1 — Anthropic Admin API extraction
  gateway-blueprint/          stage 2 — Foundry + APIM + Entra design
  client-rollout/             stage 3 — Claude Code + Claude Desktop config
  otel-telemetry/             stage 4 — OTLP via APIM into Application Insights
docs/
  architecture.md             end-to-end request and identity flow
```

Each skill carries its own `references/` (detailed, verified reference material) and
`assets/` (templates to fill in). Skills read their references before answering
detailed questions rather than working from memory.

## Security notes

- No artifact should ever contain a secret. Secrets belong in APIM named values marked
  `--secret true`, Key Vault, or Container Apps secrets, and are referenced by name.
- Per-user telemetry dimensions (`UserName`, `Subject`, `user.email`) are personal
  data. The skills surface this as a decision rather than enabling it by default.
- `OTEL_LOG_USER_PROMPTS` exports prompt text off the developer's machine. Off unless
  explicitly approved.

## License

MIT — see [LICENSE](LICENSE).
