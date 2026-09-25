# APIM as an AI gateway for Anthropic on Foundry

Reference for the `gateway-blueprint` skill. Everything here was verified against a
working deployment.

## Foundry backend

Azure AI Foundry serves a **native Anthropic Messages API** under the `/anthropic`
path of the resource endpoint:

```
https://<FOUNDRY_RESOURCE>.services.ai.azure.com/anthropic
```

A client calling `POST {base}/v1/messages` therefore reaches
`https://<FOUNDRY_RESOURCE>.services.ai.azure.com/anthropic/v1/messages`. This is why
APIM can be a pure pass-through: no path rewriting, no body translation.

Two working authentication options for the APIM → Foundry hop:

| Mode | Backend `credentials` | Notes |
| --- | --- | --- |
| API key | `header: { "x-api-key": ["{{<named-value>}}"] }` | Simplest. Store the Foundry key as a **secret** named value. |
| Managed identity | `managedIdentity: { "resource": "https://cognitiveservices.azure.com/" }` | Preferred. No secret to rotate. Requires an RBAC role assignment on the Foundry resource for APIM's system-assigned identity. |

For managed identity, the APIM system-assigned identity needs a data-plane role on
the Foundry resource (`Cognitive Services User` covers inference). Grant it with
`az role assignment create --assignee <APIM_PRINCIPAL_ID> --role "Cognitive Services User" --scope <FOUNDRY_RESOURCE_ID>`.

Enable the identity and read its principal id:

```bash
az apim show -g <APIM_RG> -n <APIM_NAME> --query "identity.principalId" -o tsv
```

Backends are **not** covered by the `az apim` CLI. Create and read them with `az rest`
against `.../backends/<name>?api-version=2024-05-01`, or with Bicep
(`Microsoft.ApiManagement/service/backends`).

A load-balanced pool (`properties.type: "Pool"`) can spread traffic across several
Foundry resources for resilience and to widen effective TPM capacity.

## API shape

The `claude` API is a pass-through published at path `claude`, so its gateway URL is
`https://<APIM_NAME>.azure-api.net/claude`.

Operations:

- A wildcard `/*` operation for each HTTP method (GET, POST, PUT, PATCH, DELETE,
  HEAD, OPTIONS) so anything the client sends is forwarded.
- An explicit `POST /v1/messages` operation. This exists so the quota and metric
  policies can be attached at operation scope, applying only to inference calls and
  not to model listing or health probes.

`subscriptionRequired` should be `false` — authorization is the Entra token, not an
APIM subscription key. If you leave it `true`, clients must also send
`Ocp-Apim-Subscription-Key`, which Claude Code and Claude Desktop will not do.

## Policies

### Scope and order

APIM evaluates policy from outermost to innermost: Global → Product → API →
Operation. `<base />` is where the outer scope's policy is spliced in. The API-scope
policy validates the token and pins the backend; the operation-scope policy reads the
already-decoded token out of `context.Variables["jwt"]`, so it must appear *after*
the API-scope `<base />`.

### `validate-azure-ad-token`

```xml
<validate-azure-ad-token tenant-id="{{tenant-id}}" output-token-variable-name="jwt">
    <audiences>
        <audience>{{llm-api-audience}}</audience>
    </audiences>
</validate-azure-ad-token>
```

Attributes: `tenant-id`, `header-name` (default `Authorization`, scheme `Bearer`),
`query-parameter-name`, `token-value`, `failed-validation-httpcode`,
`failed-validation-error-message`, `output-token-variable-name`. Child elements:
`<client-application-ids>`, `<backend-application-ids>`, `<audiences>`, `<issuers>`,
`<required-claims>`.

Because it reads `Authorization: Bearer` by default, the client must send the Entra
access token in that header — which is exactly what Claude Code's `apiKeyHelper`
produces and what Claude Desktop's OIDC `bearerTokenType: "access_token"` sends.

**Audience mismatch is the most common 401.** The `aud` claim is `api://<APP_ID>` for
v1 tokens and the bare app id GUID for v2 tokens
(`api.requestedAccessTokenVersion`). List both audiences unless you are certain which
version you issue.

### The `Jwt` object and claim typing

This trips people up, and both forms below are correct — they are not interchangeable:

```csharp
((Jwt)context.Variables["jwt"]).Claims["groups"]                       // string[]  — indexer returns ALL values
((Jwt)context.Variables["jwt"]).Claims.GetValueOrDefault("name", "x")  // string    — returns the FIRST value
```

So a multi-valued claim like `groups` must be read with the indexer (guarded by
`ContainsKey`), while single-valued claims like `name` and `sub` are read with
`GetValueOrDefault`. Using `GetValueOrDefault("groups", ...)` would collapse the array
to its first element and silently break multi-group users.

### `llm-token-limit`

```xml
<llm-token-limit
    counter-key="@((string)context.Variables["jwtSubject"])"
    token-quota="@(Convert.ToInt64(context.Variables["quota"]))"
    token-quota-period="Daily"
    estimate-prompt-tokens="false"
    remaining-quota-tokens-header-name="x-remaining-quota-tokens" />
```

- `counter-key` — the quota bucket. Using the token `sub` claim gives per-user quotas.
- `token-quota` + `token-quota-period` — a renewing allowance.
  Period values: `Hourly`, `Daily`, `Weekly`, `Monthly`, `Yearly`.
- `tokens-per-minute` — an alternative/additional sustained-rate limit.
- `estimate-prompt-tokens` — `false` bills actual usage reported by the backend,
  which is accurate but allows a single request to overshoot the remaining balance.
  `true` pre-estimates and rejects earlier, at the cost of accuracy.
- Reporting headers: `remaining-quota-tokens-header-name`,
  `remaining-tokens-header-name`, `tokens-consumed-header-name`,
  `retry-after-header-name`.

The `<llm-*>` policy family is the backend-agnostic form and is what you want for an
Anthropic backend; the `<azure-openai-*>` variants are specific to Azure OpenAI.

Verified working on APIM **Basic v2**. Consumption does not support managed identity.

### `llm-emit-token-metric`

```xml
<llm-emit-token-metric namespace="ClaudeCode">
    <dimension name="API ID" />
    <dimension name="UserName" value="@((string)context.Variables["jwtName"])" />
</llm-emit-token-metric>
```

Emits prompt/completion/total token counts as Azure Monitor custom metrics. Maximum
10 dimensions. `<dimension name="X" />` without `value` resolves a built-in
(`API ID`, `Operation ID`, `Product ID`, `User ID`, `Subscription ID`, `Location`,
`Gateway ID`).

**This policy requires an Application Insights logger attached to the API.** Without
one, the metric is computed and discarded with no error anywhere. If a user reports
"no metrics", check the logger before touching the policy.

### Policy fragments

Reusable XML spliced in with `<include-fragment fragment-id="..." />`. Managed via
`.../policyFragments/<id>?api-version=2024-05-01` with `az rest`; no `az apim` CLI
coverage. The fragment body is a `<fragment>` root element.

## Named values

```bash
az apim nv create -g <APIM_RG> --service-name <APIM_NAME> \
  --named-value-id llm-tier-gold-quota --display-name llm-tier-gold-quota --value 1000000

az apim nv create -g <APIM_RG> --service-name <APIM_NAME> \
  --named-value-id anthropic-x-api-key --display-name anthropic-x-api-key \
  --value "<KEY>" --secret true
```

Referenced in policy as `{{named-value-id}}`. Use hyphens, not underscores, and keep
the id and display name identical — it makes policy review far easier.

Named values are substituted as **raw text** before the policy is parsed. That means
a value containing `"` or `&` will corrupt the policy XML, and a numeric value
substituted into a C# expression (like `{{llm-tier-gold-quota}}`) must contain digits
only.

The quota tier set:

| Named value | Example | Meaning |
| --- | --- | --- |
| `tenant-id` | `<TENANT_ID>` | Entra tenant for token validation |
| `llm-api-audience` | `api://<GATEWAY_APP_ID>` | Expected `aud` claim |
| `llm-tier-gold-group` | `<GOLD_GROUP_OBJECT_ID>` | Entra **security group** object id |
| `llm-tier-gold-quota` | `1000000` | Tokens per period for that tier |
| `llm-tier-silver-group` | `<SILVER_GROUP_OBJECT_ID>` | |
| `llm-tier-silver-quota` | `500000` | |

## Read-only export

To inventory an existing gateway without changing it:

```bash
SUB=$(az account show --query id -o tsv)
BASE="https://management.azure.com/subscriptions/$SUB/resourceGroups/<APIM_RG>/providers/Microsoft.ApiManagement/service/<APIM_NAME>"

az apim api list -g <APIM_RG> --service-name <APIM_NAME> -o json
az apim nv list  -g <APIM_RG> --service-name <APIM_NAME> --query "[?secret==\`false\`]" -o json
az rest --method GET --url "$BASE/backends?api-version=2024-05-01" -o json
az rest --method GET --url "$BASE/policyFragments?api-version=2024-05-01" -o json

# Policy XML — must go to a file on Windows (UTF-8 BOM breaks the CLI's stdout encoder)
az rest --method GET \
  --url "$BASE/apis/<API_ID>/policies/policy?api-version=2024-05-01&format=rawxml" \
  --output-file policy.xml
```

Never print the value of a named value whose `secret` is `true`.
