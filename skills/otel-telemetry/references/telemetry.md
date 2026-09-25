# Telemetry reference

Verified against a working Azure deployment and the Claude Code monitoring
documentation. Read this before writing backend definitions or queries.

Canonical client-side doc: https://code.claude.com/docs/en/monitoring-usage
(the older `docs.claude.com/en/docs/claude-code/monitoring-usage` path 301s here).

## Signal routing

Enabling OTLP on a workspace-based Application Insights component auto-creates a Data
Collection Endpoint (DCE) and Data Collection Rule (DCR). Each signal has its own host,
stream and final destination:

| Signal | DCE host | Ingestion stream | Lands in | Query with |
| --- | --- | --- | --- | --- |
| Traces | `<DCE_HOST>.ingest.monitor.azure.com` | `Microsoft-OTLP-Traces` | Log Analytics → `OTelSpans`, `OTelEvents`, `OTelResources` | KQL |
| Logs | `<DCE_HOST>.ingest.monitor.azure.com` | `Microsoft-OTLP-Logs` | Log Analytics → `OTelLogs` | KQL |
| Metrics | `<DCE_HOST>.`**`metrics.`**`ingest.monitor.azure.com` | `Microsoft-OtelMetrics` | Azure Monitor Workspace (Prometheus) | PromQL |

`<DCE_HOST>` has the form `managed-<AI_NAME>-dce-<SUFFIX>.<REGION>-1`.

Three traps live in that table:

- The **metrics host is different** — `.metrics.ingest.` not `.ingest.`
- The **metrics stream is `Microsoft-OtelMetrics`**, not `Microsoft-OTLP-Metrics`. It
  breaks the naming pattern of the other two.
- **Metrics do not land in Log Analytics at all.** No KQL query will find them. They go
  to a Prometheus-backed Azure Monitor Workspace.

Full URL shape (the value APIM backends use, minus the `/v1/<signal>` suffix):

```
https://<DCE_HOST>.ingest.monitor.azure.com/dataCollectionRules/<DCR_IMMUTABLE_ID>/streams/<STREAM>/otlp
```

The DCR's ingestion streams fan out to differently-named output streams internally
(`Microsoft-OTLP-Traces` → `Microsoft-OTel-Traces-Spans` / `-Events` / `-Resources`).
Only the *ingestion* stream name appears in a backend URL.

## Reading the configuration off Azure (read-only)

The component exposes everything needed. Prefer this over constructing URLs:

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RG>/providers/microsoft.insights/components/<AI_NAME>?api-version=2020-02-02" \
  --query "properties.{traces:OTLPTracesEndpoint,metrics:OTLPMetricsEndpoint,logs:OTLPLogsEndpoint,dcr:DataCollectionRuleResourceId,amw:AzureMonitorWorkspaceResourceId,amwMode:AzureMonitorWorkspaceIngestionMode,ingestion:IngestionMode,workspace:WorkspaceResourceId}"
```

| Property | Must be | Meaning |
| --- | --- | --- |
| `IngestionMode` | `LogAnalytics` | Workspace-based component. Classic cannot do OTLP. |
| `AzureMonitorWorkspaceIngestionMode` | `Enabled` | Required for **metrics** only. Disabled ⇒ traces and logs still work, metrics silently vanish. |
| `OTLP*Endpoint` | present | Absent ⇒ OTLP not enabled on this component. |
| `DataCollectionRuleResourceId` | present | Points into the managed resource group. |

The managed resource group is named `ai_<AI_NAME>_<APP_ID_GUID>_managed`, where
`<APP_ID_GUID>` is the component's `AppId` (also the `ApplicationId=` field of its
connection string). The DCR inside it is `managed-<AI_NAME>-dcr`. Neither lives in the
component's own resource group.

Useful cross-checks:

```bash
# Every Application Insights component and whether it is workspace-based
az monitor app-insights component show \
  --query "[].{name:name,rg:resourceGroup,mode:properties.IngestionMode}" -o table

# Does the APIM identity already have ingestion rights?
az role assignment list --assignee <APIM_PRINCIPAL_ID> --all \
  --query "[?roleDefinitionName=='Monitoring Metrics Publisher'].scope" -o tsv

# Which tables exist in the Log Analytics workspace (expect OTelLogs, OTelSpans, ...)
az rest --method get \
  --url "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RG>/providers/Microsoft.OperationalInsights/workspaces/<WORKSPACE>/tables?api-version=2022-10-01" \
  --output-file tables.json
```

On Windows, always send `az rest` output to `--output-file` and read the file.
Piping to stdout crashes on a UTF-8 BOM with
`UnicodeEncodeError: 'charmap' codec can't encode character '﻿'`.

## Backend authentication

| | LLM API backend | OTLP backends |
| --- | --- | --- |
| MI resource | `https://cognitiveservices.azure.com/` | `https://monitor.azure.com` |
| Trailing slash | **yes** | **no** |
| Role needed | `Cognitive Services User` / `Foundry User` on the Foundry account | `Monitoring Metrics Publisher` on the managed DCR |

The inconsistent trailing slash is a genuine Azure quirk, not a typo. Copying one form
to the other yields a 401 on every request.

## Claude Code client configuration

Claude Code exports **three** signals: metrics, logs/events, and traces (beta, off by
default).

### Required

| Variable | Value | Note |
| --- | --- | --- |
| `CLAUDE_CODE_ENABLE_TELEMETRY` | `1` | Master switch. |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | **No default exists.** Unset ⇒ nothing exports, no error. Must be protobuf — see below. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `https://<APIM>.azure-api.net/<AI_NAME>/otlp` | Root only, **no port**; the exporter appends `/v1/<signal>`. |
| `OTEL_METRICS_EXPORTER` | `otlp` | Also accepts `console`, `prometheus`, `none`. |
| `OTEL_LOGS_EXPORTER` | `otlp` | Also accepts `console`, `none`. |

Per-signal `..._ENDPOINT` / `..._PROTOCOL` variables **override** the general one;
per-signal `..._HEADERS` are **merged** with the general one. That asymmetry matters if
you split signals across destinations.

Two endpoint/protocol failures verified against a live gateway:

- **`http/json` is rejected.** The ingestion API answers `415 UnsupportedMediaType` to
  `application/json`, so every export is dropped. `http/protobuf` is the only workable
  choice — `grpc` is not proxied here and would also disable `otelHeadersHelper`.
- **Never append a port to the endpoint.** `:443` is appended after the *path*, not the
  host, so APIM receives `/otlp:443/v1/metrics` as a literal path segment and answers
  `404 Resource not found`.

### Tracing (beta, optional)

`CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` plus `OTEL_TRACES_EXPORTER=otlp`. A deeper tier
(`ENABLE_BETA_TRACING_DETAILED=1` with `BETA_TRACING_ENDPOINT`) emits `claude_code.hook`
spans and extra content attributes, and in interactive sessions requires org
allowlisting.

### Authentication headers

| Mechanism | Where | Notes |
| --- | --- | --- |
| `OTEL_EXPORTER_OTLP_HEADERS` | env, static | e.g. `Ocp-Apim-Subscription-Key=<key>`. A shared secret per machine. |
| `otelHeadersHelper` | `settings.json` key | Script emitting a **JSON object** of headers. Re-run every 29 min (`CLAUDE_CODE_OTEL_HEADERS_HELPER_DEBOUNCE_MS`, default `1740000`). |

`otelHeadersHelper` applies only to `http/protobuf` and `http/json` — with `grpc`,
Claude Code uses the static variables only. Its output contract differs from
`apiKeyHelper`: a JSON object, not a bare token.

```bash
echo "{\"Authorization\": \"Bearer $(get-token)\"}"
```

If the helper fails, exports stop for the rest of the session and the failure surfaces
in `/status`, the debug log, and stderr for `-p` runs.

### Intervals and cardinality

| Variable | Default |
| --- | --- |
| `OTEL_METRIC_EXPORT_INTERVAL` | `60000` (60 s) |
| `OTEL_LOGS_EXPORT_INTERVAL` | `5000` (5 s) |
| `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE` | `delta` |
| `OTEL_METRICS_INCLUDE_SESSION_ID` | `true` |
| `OTEL_METRICS_INCLUDE_ACCOUNT_UUID` | `true` |
| `OTEL_METRICS_INCLUDE_VERSION` | `false` |
| `OTEL_METRICS_INCLUDE_ENTRYPOINT` | `false` |
| `OTEL_METRICS_INCLUDE_REPOSITORY` | `false` |

Temporality is worth testing rather than assuming: Claude Code sends `delta`, and a
Prometheus-backed store may expect `cumulative`. A mismatch yields plausible but wrong
totals, never an error.

`OTEL_RESOURCE_ATTRIBUTES` has a strict format — comma-separated `key=value`, no
spaces, US-ASCII excluding control characters, `"`, `,`, `;`, `\`. Percent-encode
anything else.

Claude Code does **not** pass `OTEL_*` to subprocesses (Bash tool, hooks, MCP servers,
language servers), so those do not re-report.

### Content and identity — all default to disabled

| Variable | Exports |
| --- | --- |
| `OTEL_LOG_USER_PROMPTS` | Prompt text |
| `OTEL_LOG_ASSISTANT_RESPONSES` | Response text. **Unset ⇒ inherits `OTEL_LOG_USER_PROMPTS`**; set `0` to keep redacted while logging prompts. |
| `OTEL_LOG_TOOL_DETAILS` | Tool inputs: Bash command lines, file paths, MCP/skill names |
| `OTEL_LOG_TOOL_CONTENT` | `tool.output` span event content. Requires tracing. |
| `OTEL_LOG_RAW_API_BODIES` | Full Messages API JSON — **the entire conversation history** |
| `OTEL_LOG_MANAGED_SETTINGS` | Redacted managed settings + SHA-256 digest |

`CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH` caps content attributes at `61440` UTF-16 units.

## Signal inventory

Metrics (dots become underscores in Prometheus — `claude_code.token.usage` →
`claude_code_token_usage`):

| Metric | Unit |
| --- | --- |
| `claude_code.session.count` | — |
| `claude_code.lines_of_code.count` | — |
| `claude_code.pull_request.count` | — |
| `claude_code.commit.count` | — |
| `claude_code.cost.usage` | USD |
| `claude_code.token.usage` | tokens |
| `claude_code.code_edit_tool.decision` | — |
| `claude_code.active_time.total` | s |

With `prometheus` as the sole exporter Claude Code omits the `USD`, `tokens` and `s`
units; metric names are unchanged.

Events: `claude_code.user_prompt`, `claude_code.assistant_response`,
`claude_code.tool_result`, `claude_code.tool_decision`, plus `api_request` /
`api_error`, and `api_request_body` / `api_response_body` when
`OTEL_LOG_RAW_API_BODIES` is set.

## Troubleshooting order

1. `claude --debug`, look for `[3P telemetry]`. Lines prefixed `[Anthropic telemetry]`
   are Anthropic's own operational telemetry and are not a fault.
2. APIM metrics for the OTLP API: 401 ⇒ auth; 403 ⇒ missing DCR role assignment;
   404 ⇒ duplicated `/v1/<signal>` in the backend URL.
3. Query Azure — `OTelLogs` for logs, `OTelSpans` for traces, PromQL against the Azure
   Monitor Workspace for metrics. Allow a few minutes for first ingestion.

| Symptom | Cause |
| --- | --- |
| Nothing exports, no error | `OTEL_EXPORTER_OTLP_PROTOCOL` unset |
| `415 UnsupportedMediaType` | Protocol is `http/json`; the API accepts protobuf only |
| `404 Resource not found` at APIM | `:443` on the endpoint ⇒ `/otlp:443/v1/metrics` |
| 404 at the DCE | `/v1/<signal>` left on the backend URL, or in the client endpoint |
| 403 at the backend | No `Monitoring Metrics Publisher` on the managed DCR |
| 401 at the backend | MI resource has a trailing slash |
| Traces and logs fine, no metrics | `AzureMonitorWorkspaceIngestionMode` disabled, wrong DCE host, or stream typed `Microsoft-OTLP-Metrics` |
| Metrics missing from KQL | Expected — they are in the Azure Monitor Workspace, not Log Analytics |
| Counters appear to reset | Delta/cumulative temporality mismatch |
| Telemetry stops mid-session | `otelHeadersHelper` failed; check `/status` |
