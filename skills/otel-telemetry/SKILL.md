---
name: otel-telemetry
description: Configure Claude Code OpenTelemetry export into Azure via a native OTLP ingestion API on API Management that forwards to Application Insights — no collector to run. Covers enabling OTLP on the Application Insights component, building the APIM OTLP API and its managed-identity backends, the DCR role assignment, the client env vars and otelHeadersHelper, and the queries that restore the usage visibility lost when traffic leaves Anthropic's analytics. Use when the user says "set up telemetry", "monitor Claude Code usage", "send metrics to Azure Monitor", "OTLP", "I lost my usage dashboards after migrating", or asks how to track token spend per user post-migration. Emits config for review; does not deploy.
---

# Claude Code telemetry into Azure

After migration, Anthropic's own analytics stop seeing this traffic — usage routed
through Foundry, Bedrock or Vertex is excluded from the Claude Code Analytics API. Two
independent Azure-side signals replace it:

| Signal | Source | Good for |
| --- | --- | --- |
| **Gateway metrics** | APIM `llm-emit-token-metric` → Application Insights | Token spend per user/model, quota enforcement. Authoritative for billing. |
| **Client telemetry** | Claude Code OTLP → APIM → Application Insights | Sessions, lines of code, commits/PRs, tool decisions, cost estimates, errors. Developer-experience view. |

They answer different questions and neither substitutes for the other. The gateway sees
every billable token but knows nothing about what the developer was doing; the client
sees the workflow but can be disabled by the user. Set up both, and prefer the gateway
metric when the two disagree on token counts.

## Topology — APIM as the OTLP endpoint

Application Insights now accepts OTLP directly through a Data Collection Endpoint. APIM
fronts it, so there is **no OpenTelemetry Collector to deploy, scale or patch**:

```
Claude Code ──OTLP/http-protobuf──► APIM  https://<APIM>.azure-api.net/<AI_NAME>/otlp
   (3 signals)                        │      POST /v1/traces  /v1/metrics  /v1/logs
                                      │
                                      │  managed identity → https://monitor.azure.com
                                      ▼
                           Data Collection Endpoint (auto-created)
                             /dataCollectionRules/<DCR_IMMUTABLE_ID>/streams/<STREAM>/otlp
                                      │
                       ┌──────────────┴───────────────┐
                       ▼                              ▼
             Log Analytics workspace        Azure Monitor Workspace
             OTelLogs / OTelSpans           (Prometheus)
             OTelEvents / OTelResources     claude_code.* metrics
             → KQL                          → PromQL
```

Use APIM rather than pointing clients straight at the DCE: clients then need no Azure
RBAC, the ingestion endpoint is not exposed to developer machines, and telemetry reuses
the same gateway hostname, auth model and policy surface as the LLM traffic.

**Two stores, two query languages.** Traces and logs land in Log Analytics and are
queried with KQL. Metrics land in an Azure Monitor Workspace and are queried with
PromQL. Client metrics do **not** appear in `customMetrics`/`AppMetrics` — that table
holds the *gateway* metrics from `llm-emit-token-metric`, which is a separate path.
Expecting one KQL query to cover both is the most common wrong assumption here.

## Steps

### 1. Prepare the Application Insights component

Use a **separate** Application Insights component from the one receiving gateway
metrics. Client telemetry is high-volume and user-attributable; gateway metrics are the
billing record. Keeping them apart lets you set retention, sampling and access
independently.

Requirements:

- **Workspace-based** Application Insights (`IngestionMode: LogAnalytics`). Classic
  components cannot do OTLP.
- For metrics, the component must be linked to an Azure Monitor Workspace —
  `AzureMonitorWorkspaceIngestionMode` must be `Enabled`. Without it, traces and logs
  still flow and metrics are silently dropped.

Enabling OTLP auto-creates a Data Collection Endpoint and Data Collection Rule in a
**managed resource group** named `ai_<AI_NAME>_<APP_ID_GUID>_managed`. This is not the
component's own resource group — look there for the DCR, and do not hand-author it.

### 2. Read the OTLP endpoints off the component (read-only)

The component exposes all three endpoints as properties. Never hand-assemble these
URLs — the host and stream name differ per signal in ways that are easy to get wrong:

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RG>/providers/microsoft.insights/components/<AI_NAME>?api-version=2020-02-02" \
  --query "properties.{traces:OTLPTracesEndpoint,metrics:OTLPMetricsEndpoint,logs:OTLPLogsEndpoint,dcr:DataCollectionRuleResourceId,amwMode:AzureMonitorWorkspaceIngestionMode,ingestion:IngestionMode}"
```

If `OTLPTracesEndpoint` and friends are absent, OTLP is not enabled on the component
yet. Record what you find in the migration profile under `telemetry:`.

See `${CLAUDE_PLUGIN_ROOT}/skills/otel-telemetry/references/telemetry.md` for the full
endpoint / stream / destination table before writing any backend definitions.

### 3. Create the OTLP API in APIM

Import `${CLAUDE_PLUGIN_ROOT}/skills/otel-telemetry/assets/apim/otlp-ingestion.openapi.yaml`
— three `POST` operations at `/v1/traces`, `/v1/metrics`, `/v1/logs` under an API path
of `<AI_NAME>/otlp`.

The API path must end in `/otlp` and the operations must be exactly `/v1/<signal>`,
because the OTLP HTTP exporter appends `/v1/<signal>` to whatever endpoint it is given.

Then, per operation, a backend and a one-line policy:

- Backends: `${CLAUDE_PLUGIN_ROOT}/skills/otel-telemetry/assets/apim/otlp-backends.template.json`
- Policy: `${CLAUDE_PLUGIN_ROOT}/skills/otel-telemetry/assets/apim/otlp-operation.policy.xml`

Each backend URL is the component's OTLP endpoint **with the trailing `/v1/<signal>`
removed**, ending at `/otlp`. APIM re-appends the operation's URL template, reproducing
the full endpoint. Leaving `/v1/traces` on the backend URL yields
`/otlp/v1/traces/v1/traces` and a 404 that reports as "no data arriving".

Each backend authenticates with the APIM **system-assigned managed identity** against
resource `https://monitor.azure.com` — note there is **no trailing slash**, unlike the
Foundry backend's `https://cognitiveservices.azure.com/`.

### 4. Grant the APIM identity ingestion rights on the DCR

Without this every export fails 403, and Claude Code surfaces it only in `--debug`:

```bash
# Read the current state first — this skill does not assign roles.
az role assignment list --assignee <APIM_PRINCIPAL_ID> --all \
  --query "[?roleDefinitionName=='Monitoring Metrics Publisher'].scope"
```

The runbook step is **Monitoring Metrics Publisher** scoped to the managed DCR
(`.../resourceGroups/ai_<AI_NAME>_<APP_ID>_managed/providers/Microsoft.Insights/dataCollectionRules/managed-<AI_NAME>-dcr`).
The role name mentions metrics but it governs all three OTLP streams.

### 5. Decide how clients authenticate to the OTLP API

| Option | Client config | Trade-off |
| --- | --- | --- |
| **Entra token** (recommended) | `otelHeadersHelper` → `Authorization: Bearer <token>` + `validate-azure-ad-token` on the API | Same identity model as the LLM API. No shared secret on developer machines. Revocable per user. |
| APIM subscription key | `OTEL_EXPORTER_OTLP_HEADERS=Ocp-Apim-Subscription-Key=<key>` | Simple, works immediately. A shared secret distributed to every machine, rotatable only fleet-wide. |

Prefer the Entra token. `otelHeadersHelper` is a `settings.json` key (not an env var)
that runs a script and re-runs it every 29 minutes by default, which is what makes a
short-lived Entra token viable for telemetry. It applies only to `http/protobuf` and
`http/json` — with `grpc`, Claude Code uses the static header variables only.

Scripts: `${CLAUDE_PLUGIN_ROOT}/skills/client-rollout/assets/claude-code/Get-OtlpHeaders.ps1`
and `get-otlp-headers.sh`. They emit a JSON object of headers, not a bare token — a
different contract from `apiKeyHelper`, which emits the token alone.

If you choose the Entra option, set the API's `subscriptionRequired` to false and add
`validate-azure-ad-token` mirroring the LLM API. If you keep the subscription key, the
key is a secret: it belongs in managed settings deployed by MDM, never in a repo.

### 6. Point clients at it

In the Claude Code settings `env` block (see the `client-rollout` skill):

```json
"CLAUDE_CODE_ENABLE_TELEMETRY": "1",
"OTEL_METRICS_EXPORTER": "otlp",
"OTEL_LOGS_EXPORTER": "otlp",
"OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
"OTEL_EXPORTER_OTLP_ENDPOINT": "https://<APIM_NAME>.azure-api.net/<AI_NAME>/otlp",
"OTEL_METRICS_INCLUDE_VERSION": "true"
```

- `OTEL_EXPORTER_OTLP_ENDPOINT` is the **root**, ending at `/otlp`. The exporter appends
  `/v1/metrics` and `/v1/logs` itself; including a suffix gives `/v1/metrics/v1/metrics`
  and silent 404s.
- **Do not append a port.** `:443` is appended after the *path*, not the host, so APIM
  receives `/otlp:443/v1/metrics` as a literal segment and returns
  `404 Resource not found`. Verified against a live gateway.
- **Claude Code has no default OTLP protocol.** Omitting
  `OTEL_EXPORTER_OTLP_PROTOCOL` means exports simply do not happen. Set it explicitly.
- It must be **`http/protobuf`**. The ingestion API rejects `application/json` with
  `415 UnsupportedMediaType`, so `http/json` drops every export. Verified against a live
  gateway. (`grpc` is not an option either — APIM does not proxy it here, and it would
  disable `otelHeadersHelper`.)
- Traces are beta and off by default. To enable, set `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1`
  and `OTEL_TRACES_EXPORTER=otlp`. The `/v1/traces` operation is otherwise idle — build
  it anyway so enabling tracing later needs no gateway change.
- Claude Code does **not** propagate `OTEL_*` to subprocesses (Bash tool, hooks, MCP
  servers), so those do not double-report.

### 7. Privacy decisions — raise these explicitly

These send content or identity off the developer's machine. None should be enabled
quietly:

- `OTEL_LOG_USER_PROMPTS` — prompt **text**.
- `OTEL_LOG_ASSISTANT_RESPONSES` — response text. When unset it *inherits*
  `OTEL_LOG_USER_PROMPTS`, so enabling prompts enables responses unless you set it to `0`.
- `OTEL_LOG_TOOL_DETAILS` — tool inputs, including Bash command lines and file paths.
- `OTEL_LOG_RAW_API_BODIES` — full request/response JSON, containing **the entire
  conversation history**. Treat as off-limits outside a scoped debugging window.

Claude Code also attaches `user.email` and `user.account_uuid` by default
(`OTEL_METRICS_INCLUDE_ACCOUNT_UUID` defaults to `true`). Independently, the APIM
`llm-emit-token-metric` policy carries `UserName` and `Subject`. Per-user attribution is
usually the point of the exercise, but it is personal data — confirm it is acceptable
rather than shipping it by default. Note that going direct to APIM removes the collector
tier where attributes could be stripped in transit; scrubbing now has to happen via
client settings or an APIM policy.

### 8. Confirm data is arriving

Work outward from the client:

1. `claude --debug` and look for `[3P telemetry]` errors. Lines prefixed
   `[Anthropic telemetry]` are Anthropic's separate operational telemetry and do not
   indicate a problem.
2. APIM: check the OTLP API's metrics for 2xx vs 401/403/404. A 403 here is the DCR role
   assignment; a 404 is a backend URL with a duplicated `/v1/<signal>`.
3. Query Azure. Allow several minutes for first ingestion.

Logs and traces — KQL against the Log Analytics workspace:

```kusto
// Claude Code events arriving at all, last hour
OTelLogs
| where TimeGenerated > ago(1h)
| summarize events = count() by Name = tostring(Body.name), bin(TimeGenerated, 5m)
| render timechart
```

```kusto
// Most active users by session events
OTelLogs
| where TimeGenerated > ago(7d)
| extend user = tostring(Attributes["user.email"])
| where isnotempty(user)
| summarize events = count() by user
| top 20 by events desc
```

Metrics — PromQL against the Azure Monitor Workspace, not KQL:

```promql
sum by (model) (sum_over_time({__name__="claude_code.token.usage"}[1h]))
```

Metric names keep their dots — `claude_code.token.usage`, not
`claude_code_token_usage` — so select them with `{__name__="..."}` (the workspace
accepts only `=` on `__name__`, no regex) and quote dotted labels: `by ("user.id")`.
The metric set is `claude_code.session.count`, `lines_of_code.count`, `commit.count`,
`pull_request.count`, `token.usage`, `cost.usage`, `code_edit_tool.decision`,
`active_time.total`.

**Samples are stored as deltas.** Claude Code defaults to `delta` temporality and the
workspace keeps each export as-is, so aggregate with `sum_over_time`. `rate()` and
`increase()` assume cumulative counters and return plausible-looking but wrong
numbers rather than an error.

Gateway metrics remain in the *other* component's `customMetrics` under the namespace
declared in the APIM policy. If they are missing entirely, check that an Application
Insights logger is attached to the LLM API — `llm-emit-token-metric` drops metrics
silently without one.

## What breaks silently

| Misconfiguration | Symptom |
| --- | --- |
| `OTEL_EXPORTER_OTLP_PROTOCOL` unset | No exports at all; no error |
| `OTEL_EXPORTER_OTLP_PROTOCOL` set to `http/json` | `415 UnsupportedMediaType`; every export dropped |
| `:443` appended to the endpoint | Port lands after the path ⇒ `/otlp:443/v1/metrics` ⇒ 404 |
| `/v1/<signal>` left on the backend URL | 404 at the DCE, reads as "no data" |
| `/v1/metrics` included in `OTEL_EXPORTER_OTLP_ENDPOINT` | `/v1/metrics/v1/metrics`, 404 |
| Missing **Monitoring Metrics Publisher** on the managed DCR | 403 visible only in `--debug` |
| MI resource set to `https://monitor.azure.com/` (trailing slash) | Token audience mismatch, 401 |
| `AzureMonitorWorkspaceIngestionMode` not `Enabled` | Traces and logs arrive, metrics vanish |
| Metrics stream typed `Microsoft-OTLP-Metrics` | Wrong — it is `Microsoft-OtelMetrics` |
| Metrics backend on the non-`metrics.` DCE host | Wrong host; metrics rejected |
| Looking for client metrics in `customMetrics` | Empty — they are in the Azure Monitor Workspace |
| Classic (non-workspace) Application Insights | OTLP unavailable, no endpoints exposed |

## Guardrails

- Telemetry is not a quota mechanism. Quotas are enforced by `llm-token-limit` at the
  gateway; OTel is observational and a user can turn it off.
- Metric and log volume scales with active developers. Check the Log Analytics daily cap
  and the Azure Monitor Workspace limits before a fleet rollout, or ingestion will be
  throttled and data silently dropped.
- This iteration is read-only: inspect with `az ... show/list`, emit the API definition,
  backends, policy and role-assignment commands as a runbook for a human to apply.
- An optional local collector config remains at `assets/optional-collector/` for cases
  needing on-prem scrubbing or buffering before data leaves the network. It is not the
  default path and should only be introduced if a stated requirement demands it.
