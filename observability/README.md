# Grafana dashboard — AI Gateway & Claude Code usage

[`claude-ai-gateway.dashboard.json`](claude-ai-gateway.dashboard.json) is a single,
customer-agnostic Grafana dashboard. It contains no subscription, resource or data source
IDs. Everything is selected through variables at view time.

It imports into either:

- **Application Insights → Dashboards with Grafana** in the Azure portal (no Grafana
  instance needed), or
- **Azure Managed Grafana** 11.6 or later.

## What it shows

| Row | Source | Query | Scoped to |
| --- | --- | --- | --- |
| AI Gateway — token usage | APIM `llm-emit-token-metric` → `customMetrics` | KQL | Application Insights component |
| AI Gateway — requests, errors, latency | APIM resource logs → `ApiManagementGatewayLogs` | KQL | API Management instance |
| Claude Code — client telemetry | Claude Code OTLP metrics → Azure Monitor Workspace | PromQL | `microsoft.appresourceid` label = same component |

The gateway rows cover **every client** that calls the gateway: Claude Code, Claude
Desktop and SDK callers. They are the authoritative token count. The Claude Code row adds
client-only signals (estimated cost, sessions, active time, edit decisions) and can be
split between `claude-code` and `claude-code-desktop`.

## Variables

| Variable | Purpose |
| --- | --- |
| `am_ds` | Azure Monitor data source |
| `prom_ds` | Prometheus data source for the Azure Monitor Workspace linked to the component (`AzureMonitorWorkspaceResourceId`) |
| `sub` / `rg` / `res` | Application Insights component that receives the gateway metrics and Claude Code OTLP |
| `apim` | AI Gateway (API Management) instance in `sub` |
| `user` | Filters the gateway token panels (Entra `name` claim) |
| `price_factor` | Price multiplier for gateway cost estimates (e.g. `0.85` for a negotiated discount) |
| `price_table` | Hidden constant: USD per million tokens by model family, `[input, output, cache read, cache write 5m]` |
| `client` | Filters the Claude Code panels by OTel `service.name` |

## Prerequisites per customer

1. **Gateway metrics:** the APIM policy from
   [`gateway-blueprint`](../skills/gateway-blueprint/assets/policies/v1-messages.operation.policy.xml)
   is deployed, and the API has an Application Insights diagnostic with **metrics
   enabled**. Without it the token metric is computed and dropped.
2. **Gateway logs:** an APIM diagnostic setting sends `GatewayLogs` to a Log Analytics
   workspace in **resource-specific** mode, which creates the `ApiManagementGatewayLogs`
   table. In `AzureDiagnostics` mode the second row stays empty.
3. **Claude Code metrics:** OTLP is set up as in
   [`otel-telemetry`](../skills/otel-telemetry/SKILL.md), with
   `AzureMonitorWorkspaceIngestionMode = Enabled` on the component.
4. **Conventions the queries rely on.** None of these are resource names, and all of them
   come from this plugin's blueprints:
   - Gateway token metric dimensions `UserName`, `Subject`, `model`, `quota`, `API ID` and
     `Environment`, as emitted by the blueprint policy. A customer policy with other
     dimension names leaves the per-user and per-model panels empty.
   - Claude traffic is identified by the URL containing `/v1/messages`. OTLP traffic is
     identified by `/otlp/v1/(traces|metrics|logs)`. API IDs and API names don't matter,
     and other APIs on a shared APIM instance are excluded.
   - The APIM instance is in the same subscription as the Application Insights component,
     because the `apim` dropdown lists instances in the selected subscription.
5. **Viewer roles:** *Monitoring Reader* on the component and the APIM instance
   (Log Analytics data), and *Monitoring Data Reader* on the Azure Monitor Workspace
   (Prometheus). For the portal experience, also *Reader* on the dashboard resource.

## Deploy

**Azure portal (Dashboards with Grafana):** open the Application Insights component →
**Dashboards with Grafana** → **New** → **Import** → select the JSON file → pick a
subscription, resource group and region. The dashboard is saved as a
`Microsoft.Dashboard/dashboards` resource. If it doesn't appear in the component's
gallery, add the Azure tag
`GrafanaDashboardResourceType = microsoft.insights/components`.

**Azure Managed Grafana:**

```bash
az grafana dashboard import -g <RG> -n <GRAFANA> --definition claude-ai-gateway.dashboard.json
```

**As code:** after one portal import, use **Export → Export as ARM Template** and deploy
that template to each customer with `az deployment group create`. The template embeds
this JSON unchanged.

## Colours and thresholds

Colour only marks things that need attention:

- **Volume tiles** (cost, tokens, users, sessions): value in normal text with a grey
  trend line. The value is the sum of the trend over the selected time range.
- **Token types** use the same colour on their tile and in both *Tokens by type* charts:
  input blue, output orange, cache read green, cache write amber.
- **Health tiles** have no colour while healthy and turn amber or red past a threshold:

  | Tile | Amber | Red |
  | --- | --- | --- |
  | Success rate / Telemetry ingestion success | below 99% | below 95% |
  | Throttled by Foundry (429) | ≥ 1 | ≥ 50 |
  | Backend / connection errors | ≥ 1 | ≥ 10 |
  | Unmatched requests | ≥ 1 | none |

  These are starting points. Tune them per customer under **Edit panel → Thresholds**.
  *Rejected by gateway* and *p95 latency* are deliberately left uncoloured. Rejections are
  the quota policy working as designed, and latency depends on how long each response is.

## Reading the numbers

- **Billable tokens = input + output + cache read + cache write.** APIM's own
  `Total Tokens` metric is input + output only. With Claude, cache reads usually exceed
  everything else by one or two orders of magnitude.
- **Cache write** (`Cache Creation Tokens`) is only emitted by recent APIM gateway
  versions. Periods before that read low.
- **Today's quota consumption** uses input + output for the current UTC day against the
  tier's daily quota. It approximates the `llm-token-limit` counter rather than reading it.
- **Rejected by gateway** counts 401/403/429 responses with no backend response: an
  invalid token, no tier group, or an exhausted daily quota. **Throttled by Foundry**
  counts 429s returned by the deployment. Each needs a different fix: a quota tier change
  versus more Foundry capacity.
- **Gateway cost per user** is gateway tokens × `price_table` × `price_factor`, per Entra
  user, the same identity the quota keys on. Model names are matched by family
  (`claude-opus-5-5-eu` is priced as `claude-opus-5-5`). A model missing from the table
  shows *missing* in **Usage by API and model**, and its cost reads as zero. Cache writes
  are priced at the 5-minute rate (1.25× input). The gateway metric does not separate
  1-hour writes, which cost 2× input. Haiku 5.5's higher price for prompts over 100K tokens
  is not modelled.
- **Updating prices:** edit `price_table` under **Dashboard settings → Variables**. The
  defaults are Anthropic list prices as of 2026-10-06, which is also what Claude on Foundry
  bills.
- **Claude Code's estimated cost** is the client's own estimate at list prices. Neither
  figure is your Foundry bill.
- **Claude Code users** appear as a hashed `user.id`, because Claude Code has no email
  when it authenticates through the gateway. To get readable names, set
  `OTEL_RESOURCE_ATTRIBUTES=enduser.id=<upn>` in the managed settings.

- **Commits / Pull requests show 0** until Claude itself creates one. The metrics don't
  exist before that.
- **Lines of code may show a Gateway Timeout.** In the reference environment, every query on
  `claude_code.lines_of_code.count` timed out in the Azure Monitor Workspace, even one-hour
  lookups, while the other metrics answered at once and exports returned 200. This is a
  workspace-side issue. If a customer sees it, open an Azure support case with the request
  IDs from the panel error.

## PromQL conventions used

The Azure Monitor Workspace differs from upstream Prometheus in ways that silently break
copied queries:

- Metric names keep their dots: `{__name__="claude_code.token.usage"}`. Only `=` is
  allowed on `__name__`; regex is rejected.
- Dotted labels must be quoted: `sum by ("user.id") (...)`.
- Samples are deltas: aggregate with `sum_over_time(...[$__interval])`, never `rate()`
  or `increase()`.
- `microsoft.appresourceid` is lowercase, so the component filter is case-insensitive
  (`=~"(?i)..."`).
