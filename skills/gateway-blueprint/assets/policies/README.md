# Deploying these policies

The `.xml` files in this folder are templates. Fill the placeholders, then apply them
to APIM. This plugin does not apply them for you — review each one first.

## Placeholder convention

Most files in this plugin use `<PLACEHOLDER>`. Inside XML **attribute values** that is
not legal (`<` is forbidden there and makes the file unparseable), so XML templates use
`__PLACEHOLDER__` instead. Both mean the same thing: replace before deploying.

## Order

Fragments must exist before a policy that includes them, and named values before any
policy that references them. Otherwise the policy apply fails validation.

1. Named values (`tenant-id`, `llm-api-audience`, `llm-tier-*-group`, `llm-tier-*-quota`)
2. `extract-model-query-body.fragment.xml`
3. `claude-api.policy.xml` — API scope
4. `v1-messages.operation.policy.xml` — `POST /v1/messages` operation scope

## Creating the policy fragment

The fragment is created through the management API. Its XML must be passed as a
**string** inside a JSON envelope, with `format: "rawxml"`:

```json
{
  "properties": {
    "description": "Extract the requested LLM model",
    "format": "rawxml",
    "value": "<the entire <fragment> element, as a JSON string>"
  }
}
```

Save that as `extract-model-query-body.fragment.json`, then:

```bash
az rest --method PUT \
  --url "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<APIM_RG>/providers/Microsoft.ApiManagement/service/<APIM_NAME>/policyFragments/extract-model-query-body?api-version=2024-05-01" \
  --body @extract-model-query-body.fragment.json
```

`preserveContent: true` inside the fragment is load-bearing. Without it the buffered
request body is consumed and Foundry receives an empty request.

## Reading back what is deployed

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<APIM_RG>/providers/Microsoft.ApiManagement/service/<APIM_NAME>/apis/<API_ID>/policies/policy?api-version=2024-05-01&format=rawxml" \
  --output-file api-policy.json
```

On Windows always use `--output-file` and read the file. Piping `az rest` XML output to
stdout crashes on the UTF-8 BOM with
`UnicodeEncodeError: 'charmap' codec can't encode character '﻿'`.

## Before you apply

- `llm-tier-*-group` named values must hold Entra **security group object IDs**, not app
  role IDs. An app role's GUID appears in no token; getting this wrong gives every user
  a 403 with no diagnostic.
- Quoting inside policy expressions must be XML-escaped (`&quot;`), including in
  `llm-emit-token-metric` dimension values. The Azure portal will accept unescaped
  quotes in some places and then fail at runtime.
- Verify `token-quota-period` matches what you intend. These templates use `Daily`.
