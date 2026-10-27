# Architecture

End-to-end reference for the Claude Enterprise → Anthropic on Foundry migration.

## Request flow

```
┌──────────────────┐         ┌──────────────────────────────────────┐        ┌────────────────────┐
│ Claude Code CLI  │         │      Azure API Management            │        │  Azure AI Foundry  │
│                  │         │      (AI gateway)                    │        │                    │
│ apiKeyHelper     │  Entra  │                                      │  MI /  │ /anthropic         │
│  → az account    ├────────►│ 1 validate-azure-ad-token            ├───────►│  /v1/messages      │
│    get-access-   │  JWT    │ 2 set-backend-service                │ x-api- │                    │
│    token         │ Bearer  │ 3 strip Accept-Encoding              │  key   │ Claude models      │
└──────────────────┘         │ ────────── POST /v1/messages ─────── │        └────────────────────┘
┌──────────────────┐         │ 4 extract model from body (fragment) │
│ Claude Desktop   │         │ 5 resolve tier from `groups` claim   │
│                  │  Entra  │ 6 llm-token-limit   (quota)          │
│ interactive      ├────────►│ 7 llm-emit-token-metric (metrics)    │
│ browser OIDC     │  JWT    │                                      │
└──────────────────┘         └───────────────┬──────────────────────┘
                                             │
                                             ▼
                                   Application Insights
                                   (ClaudeCode namespace)
```

Separately, Claude Code streams its own OpenTelemetry through a second APIM API:

```
Claude Code ──OTLP/http-protobuf──► APIM  /<ai-name>/otlp
  metrics                             │      POST /v1/traces  /v1/metrics  /v1/logs
  logs/events                         │
  traces (beta, opt-in)               │  managed identity → https://monitor.azure.com
                                      ▼
                      Data Collection Endpoint → Data Collection Rule
                                      │
                        ┌─────────────┴──────────────┐
                        ▼                            ▼
              Log Analytics workspace      Azure Monitor Workspace
              OTelLogs / OTelSpans         claude_code.* (Prometheus)
              OTelEvents / OTelResources
              → KQL                        → PromQL
```

Application Insights accepts OTLP natively, so there is no collector to deploy, scale
or patch. Fronting the Data Collection Endpoint with APIM keeps developer machines out
of Azure RBAC entirely — they hold a token for the gateway, nothing more — and reuses
the same hostname and policy surface as the LLM traffic.

Two consequences are easy to miss. **Metrics and logs end up in different stores with
different query languages**, so no single KQL query covers both. And **client telemetry
is a separate component from gateway metrics**: `llm-emit-token-metric` writes to its
own Application Insights via an APIM logger, which is the billing record; the OTLP path
carries the developer-experience view and can be switched off by the user.

## Why APIM is a plain pass-through

Azure AI Foundry serves a **native Anthropic Messages API** at the `/anthropic` path
of the resource endpoint:

```
https://<FOUNDRY_RESOURCE>.services.ai.azure.com/anthropic
```

A client calling `POST {base}/v1/messages` lands on
`…/anthropic/v1/messages`. Because the wire protocol on both sides of the gateway is
the Anthropic Messages API, APIM needs no path rewriting and no body translation. That
is what makes an unmodified Claude Code and Claude Desktop work against it.

## Identity and quota

The gateway derives everything from one Entra ID access token.

```
User ──az login / browser──► Entra ID
                               │  audience:  api://<GATEWAY_APP_ID>
                               │  scope:     access_as_user
                               ▼
                         access token
                           aud    → validate-azure-ad-token
                           sub    → llm-token-limit counter-key   (per-user quota)
                           groups → tier lookup                   (which quota)
                           name   → metric dimension
```

Tier resolution, in the operation policy:

```
groups claim (group object IDs)
        │
        ├── matches llm-tier-gold-group   → quota = llm-tier-gold-quota
        ├── matches llm-tier-silver-group → quota = llm-tier-silver-quota
        └── no match                      → quota = 0 → HTTP 403
```

A user in several tier groups gets the highest quota (`.Max()`). A user in none is
rejected — the design fails closed.

### Groups, not app roles

The app roles on the registration exist **only** so that security *groups* can be
assigned to the application, which is what makes `groupMembershipClaims:
"ApplicationGroup"` emit those groups in the token.

What actually appears in a token:

| | Contains |
| --- | --- |
| `groups` claim | security group **object IDs** |
| `roles` claim | app role **`value` strings** (e.g. `Claude.Tier.Gold`) |
| — | an app role's own `id` GUID appears **nowhere** |

So the `llm-tier-*-group` named values hold group object IDs. This is the single most
common configuration error in this design, and it presents as a blanket 403 with no
diagnostic.

`ApplicationGroup` is also the mitigation for **groups overage**: past roughly 200
groups, Entra replaces the `groups` claim with a `_claim_names` / `_claim_sources`
pointer that APIM cannot follow. Scoping the claim to application-assigned groups
keeps it small and bounded.

## Mapping Claude Enterprise concepts to Azure

| Claude Enterprise | Azure equivalent |
| --- | --- |
| Workspace | Entra security group (one per distinct quota tier) |
| Workspace spend limit | `llm-tier-<name>-quota` + `token-quota-period` |
| Workspace rate limit | `tokens-per-minute` on `llm-token-limit` |
| Workspace member | group membership |
| Org role / workspace role | Entra group membership + app role assignment |
| API key | Entra access token (short-lived, per user) |
| Usage & cost reports | APIM token metrics + Claude Code OTel |
| Claude Code analytics | Claude Code OTLP → APIM → Application Insights |

The mapping is not one-to-one, and two differences matter:

- Claude Enterprise limits **spend in dollars**; APIM limits **tokens**. Converting
  requires a per-model price assumption — record it in the migration profile so the
  number can be revisited when pricing changes.
- Anthropic workspaces isolate API keys; Entra groups isolate *people*. A user in two
  tier groups gets the higher quota rather than two separate budgets.

## What breaks silently

Collected here because each one produces no error message:

| Misconfiguration | Symptom |
| --- | --- |
| App role IDs in `llm-tier-*-group` | Every user gets 403 |
| `groupMembershipClaims` not `ApplicationGroup` | Users in many groups get 403, seemingly at random |
| `Accept-Encoding` not stripped | Token counts and quotas read zero |
| No Application Insights logger on the API | `llm-emit-token-metric` emits nothing |
| `preserveContent: true` missing from the fragment | Backend receives an empty body |
| `OTEL_EXPORTER_OTLP_ENDPOINT` includes `/v1/metrics` | Exporter posts to `/v1/metrics/v1/metrics`, 404 |
| `OTEL_EXPORTER_OTLP_PROTOCOL` unset | No telemetry ever exports — Claude Code has no default |
| `OTEL_EXPORTER_OTLP_PROTOCOL` set to `http/json` | `415 UnsupportedMediaType` on every export |
| `:443` appended to the OTLP endpoint | Port lands after the path ⇒ `/otlp:443/v1/metrics` ⇒ 404 |
| `/v1/<signal>` left on an OTLP backend URL | 404 at the DCE, presents as "no data arriving" |
| OTLP backend identity resource written `https://monitor.azure.com/` | Trailing slash ⇒ audience mismatch ⇒ 401 |
| Missing `Monitoring Metrics Publisher` on the managed DCR | 403 on export, visible only under `claude --debug` |
| `AzureMonitorWorkspaceIngestionMode` disabled | Traces and logs arrive; metrics vanish without error |
| Metrics stream written `Microsoft-OTLP-Metrics` | Wrong name — it is `Microsoft-OtelMetrics` |
| Delta/cumulative temporality mismatch | Counters look like they reset; totals wrong, never an error |
| Static `ANTHROPIC_API_KEY` set with `apiKeyHelper` | Works until the token expires, then 401 |
| Audience/token-version mismatch | 401 at the gateway |

## Operational notes

- **Quota overshoot.** With `estimate-prompt-tokens="false"` the gateway bills actual
  usage reported by the backend, so a single large request can exceed the remaining
  balance before it is counted. Size quotas with headroom.
- **Agentic consumption.** An agentic client can consume a very large quota in one
  session — sub-agent fan-out in particular. Quota sizing based on chat-era usage will
  under-provision badly.
- **Quota is per user, per period.** The `sub` counter-key means a user's quota is
  shared across every machine and client they use.
