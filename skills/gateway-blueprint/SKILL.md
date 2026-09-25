---
name: gateway-blueprint
description: Design and emit the Azure AI Gateway configuration that replaces Claude Enterprise governance — Azure AI Foundry backend, API Management pass-through API, token-quota and metric policies, and the Entra ID app registration with group-based quota tiers. Use when the user says "plan the Azure gateway", "generate the APIM policies", "set up Anthropic on Foundry", "configure the AI gateway", "map my Claude tiers to Entra groups", or asks what Azure resources the migration needs. Read-only: it inspects existing Azure state and writes reviewable artifacts, never mutating the subscription.
---

# Azure AI Gateway blueprint

Turn a Claude Enterprise inventory into a concrete, reviewable Azure configuration.

**This skill is read-only against Azure.** It runs `list`/`show` commands to discover
what already exists, then writes artifacts to `./migration/azure/` for a human to
review and apply. It never creates, updates or deletes an Azure resource. If the user
asks you to actually deploy, stop and tell them this iteration emits artifacts only.

## Target architecture

```
Claude Code CLI ─┐
                 ├─► APIM  https://<APIM_NAME>.azure-api.net/claude/v1/messages
Claude Desktop ──┘        │
                          │  validate-azure-ad-token  (Entra JWT, audience = api://<GATEWAY_APP_ID>)
                          │  llm-token-limit          (per-user quota keyed on `sub`, tier from `groups`)
                          │  llm-emit-token-metric    (→ Application Insights)
                          ▼
                 Azure AI Foundry
                 https://<FOUNDRY_RESOURCE>.services.ai.azure.com/anthropic
```

The critical property: **Azure AI Foundry exposes a native Anthropic Messages API at
the `/anthropic` path suffix.** Because of that, APIM is a plain pass-through — no
request or response rewriting — and Claude Code and Claude Desktop talk to it with
their normal Anthropic wire protocol. Clients append `/v1/messages` to the base URL.

See `references/apim-gateway.md` for the full APIM reference and
`references/entra-id.md` for the identity and quota-tier design. Read those before
answering detailed questions; do not guess at policy attributes.

## Steps

### 1. Discover what already exists

Prefer reusing resources over inventing new ones. Run these read-only checks and
record what you find:

```bash
# Subscription + tenant context
az account show --query "{sub:id,tenant:tenantId,name:name}" -o json

# Existing Foundry / Azure AI Services resources
az cognitiveservices account list \
  --query "[?kind=='AIServices'].{name:name,rg:resourceGroup,loc:location,endpoint:properties.endpoint}" -o json

# Existing API Management instances (note the SKU — see below)
az apim list --query "[].{name:name,rg:resourceGroup,sku:sku.name,gw:gatewayUrl}" -o json

# What is already configured on a candidate APIM
az apim api list  --resource-group <APIM_RG> --service-name <APIM_NAME> \
  --query "[].{name:name,path:path}" -o json
az apim nv list   --resource-group <APIM_RG> --service-name <APIM_NAME> \
  --query "[].{id:name,secret:secret}" -o json

# Backends and policy fragments have no `az apim` coverage — use az rest
SUB=$(az account show --query id -o tsv)
BASE="https://management.azure.com/subscriptions/$SUB/resourceGroups/<APIM_RG>/providers/Microsoft.ApiManagement/service/<APIM_NAME>"
az rest --method GET --url "$BASE/backends?api-version=2024-05-01" \
  --query "value[].{name:name,url:properties.url,mi:properties.credentials.managedIdentity.resource}" -o json
az rest --method GET --url "$BASE/policyFragments?api-version=2024-05-01" --query "value[].name" -o json
```

Existing Entra state:

```bash
az ad app list --display-name "<GATEWAY_APP_NAME>" --query "[].{name:displayName,appId:appId,id:id}" -o json
az ad group list --display-name "<TIER_GROUP_PREFIX>" --query "[].{name:displayName,id:id}" -o json
```

**Windows note:** `az rest` with `&format=rawxml` writes a UTF-8 BOM that crashes the
Azure CLI's console encoder. Always use `--output-file <path>` when fetching policy
XML, then read the file.

### 2. Map tiers to Entra groups

From the Claude Enterprise inventory (see the `enterprise-inventory` skill), each
workspace or team with a distinct quota becomes one Entra **security group** plus one
APIM named-value pair.

The single most common mistake, and the one to actively check for:

> `llm-tier-<name>-group` must hold the **security group's object ID**, not the app
> role's ID. The `groups` claim carries group object IDs. App role assignments appear
> in the `roles` claim as the role's `value` string, and an app role's own GUID never
> appears in any token. Putting an app role ID here yields quota = 0 and every caller
> gets HTTP 403.

Verify a GUID really is a group before writing it into a named value:

```bash
az ad group show --group <GUID> --query "{name:displayName,security:securityEnabled}" -o json
```

### 3. Emit artifacts

Write to `./migration/azure/`, substituting discovered values for placeholders:

| Artifact | Source template |
| --- | --- |
| `policies/claude-api.policy.xml` | `${CLAUDE_PLUGIN_ROOT}/skills/gateway-blueprint/assets/policies/claude-api.policy.xml` |
| `policies/v1-messages.operation.policy.xml` | `${CLAUDE_PLUGIN_ROOT}/skills/gateway-blueprint/assets/policies/v1-messages.operation.policy.xml` |
| `policies/extract-model-query-body.fragment.xml` | `${CLAUDE_PLUGIN_ROOT}/skills/gateway-blueprint/assets/policies/extract-model-query-body.fragment.xml` |
| `entra/app-registration.json` | `${CLAUDE_PLUGIN_ROOT}/skills/gateway-blueprint/assets/entra/app-registration.template.json` |
| `named-values.md` | generated from the tier mapping |
| `RUNBOOK.md` | the ordered apply steps, generated |

Never write a real secret into an artifact. Named values holding API keys must be
created as `--secret true` and referenced by name only.

### 4. Produce the runbook

The runbook is the deliverable a platform engineer executes. Order matters —
dependencies flow downward:

1. Foundry resource + Claude model deployment.
2. Entra app registration, `access_as_user` scope, app roles, Azure CLI pre-authorization.
3. Tier security groups; assign each to the app (via app role assignment).
4. APIM named values (`tenant-id`, `llm-api-audience`, `llm-tier-*-group`, `llm-tier-*-quota`).
5. APIM backend `anthropic-endpoint` → the Foundry `/anthropic` endpoint.
6. Policy fragment `extract-model-query-body`.
7. The `claude` API with a wildcard `/*` operation plus an explicit `POST /v1/messages` operation.
8. API-scope policy, then the `/v1/messages` operation-scope policy.
9. Application Insights logger on the API — **without it `llm-emit-token-metric` silently drops every metric.**

Include the exact `az` command for each step, but present them as steps for a human
to run. Do not run them.

## Guardrails

- APIM SKU must support the GenAI policies and managed identity. Basic v2 is known
  to work. Consumption does not support managed identity; check before recommending.
- `<set-header name="Accept-Encoding" exists-action="delete" />` is load-bearing. A
  compressed response body cannot be parsed for token counts, so quotas and metrics
  silently read zero.
- `preserveContent: true` in the model-extraction fragment is load-bearing. Without
  it the buffered body is consumed and the backend receives an empty request.
- `llm-emit-token-metric` dimensions carrying `UserName` and `Subject` are personal
  data. Flag this to the user rather than enabling it silently.
- Quota overshoot is expected with `estimate-prompt-tokens="false"`: a single large
  request can exceed the remaining balance before it is counted. Size quotas with
  headroom, and warn the user that an agentic client can consume a very large daily
  quota in a single session.
