# Entra ID identity and quota tiers

Reference for the `gateway-blueprint` skill. This is the part of the migration that
most often ships subtly broken, because a misconfiguration here fails as a blanket
HTTP 403 with no diagnostic.

## What the gateway needs from a token

The APIM policy needs three things out of the caller's access token:

| Claim | Used for | Must be present because |
| --- | --- | --- |
| `aud` | `validate-azure-ad-token` audience match | Otherwise 401 |
| `sub` | `llm-token-limit` counter key | Quota is per user |
| `groups` | tier lookup → token quota | Otherwise quota = 0 → 403 |

## Groups vs app roles — get this right

The working design uses **security groups** for tiering. The app roles exist only as
the mechanism that lets a *group* be assigned to the application.

What actually lands in a token:

- `groups` claim → security group **object IDs** (GUIDs).
- `roles` claim → the app role's **`value` string** (e.g. `Claude.Tier.Gold`).
- An app role's own `id` GUID → **never appears in any token.**

Therefore `llm-tier-<name>-group` named values must hold **group object IDs**. This is
worth stating plainly because the mistake is easy to make and invisible: copying app
role IDs into those named values produces a dictionary that nothing ever matches, so
`.DefaultIfEmpty(0).Max()` returns 0 and every user is rejected with
`403 No LLM quota assigned`.

Verify before writing a GUID into a named value:

```bash
az ad group show --group <GUID> --query "{name:displayName,security:securityEnabled}" -o json
```

If that errors, the GUID is not a group.

An alternative design matches `roles` claim values instead of `groups` object IDs.
It is arguably cleaner (no opaque GUIDs in named values, no overage risk) but it is
not what the reference deployment uses. Do not silently switch a user between the two
— the policy expression and the named values must agree.

## groupMembershipClaims and the overage trap

```json
"groupMembershipClaims": "ApplicationGroup"
```

Allowed values: `None`, `SecurityGroup`, `ApplicationGroup`, `DirectoryRole`, `All`.

`ApplicationGroup` emits only the groups **assigned to this application**, which is
both what the quota lookup needs and the mitigation for the overage problem:

> If the token would carry more than roughly 200 groups, Entra ID drops the `groups`
> claim entirely and substitutes `_claim_names` / `_claim_sources` pointing at a
> Microsoft Graph URL. The APIM policy cannot follow that pointer, so the quota
> lookup finds nothing and **every affected user is locked out with 403**.

In a large directory, `SecurityGroup` or `All` will hit this for senior staff who
accumulate group memberships — the failure appears user-specific and random, which
makes it painful to diagnose. Keep `ApplicationGroup`, and assign only the small set
of tier groups to the application.

You also need the optional claim enabled:

```json
"optionalClaims": {
  "accessToken": [{ "name": "groups", "essential": false, "additionalProperties": [] }]
}
```

Assigning a **group** (as opposed to an individual user) to an app role requires
Entra ID P1 or P2. Confirm licensing before recommending this design.

## Token version, audience and issuer

`api.requestedAccessTokenVersion` decides the token shape:

| Version | `aud` | `iss` |
| --- | --- | --- |
| 1 | `api://<GATEWAY_APP_ID>` | `https://sts.windows.net/<TENANT_ID>/` |
| 2 | `<GATEWAY_APP_ID>` (bare GUID) | `https://login.microsoftonline.com/<TENANT_ID>/v2.0` |

Three places must agree with this choice:

1. APIM `<audiences>` — list both forms to be safe.
2. Claude Desktop's `inference.credential.oidc.issuer`.
3. Any `<issuers>` element you add to `validate-azure-ad-token`.

## Letting the Azure CLI mint tokens

Claude Code's `apiKeyHelper` script shells out to the Azure CLI. For that to work
without a separate consent prompt, pre-authorize the Azure CLI's well-known public
client id against the `access_as_user` scope:

```json
"preAuthorizedApplications": [
  {
    "appId": "04b07795-8ddb-461a-bbee-02f9e1bf7b46",
    "delegatedPermissionIds": ["<ACCESS_AS_USER_SCOPE_ID>"]
  }
]
```

`04b07795-8ddb-461a-bbee-02f9e1bf7b46` is Microsoft's Azure CLI client id — a
first-party constant, identical in every tenant.

Then this works for any signed-in user:

```bash
az account get-access-token --scope "api://<GATEWAY_APP_ID>/access_as_user" --query accessToken -o tsv
```

Use `--scope` (v2 semantics, scope-qualified) rather than `--resource` (v1).

## Read-only inspection

```bash
# The app registration as Graph sees it
az ad app show --id <GATEWAY_APP_ID> -o json

# Which principals (users AND groups) are assigned to the app's roles
SP=$(az ad sp show --id <GATEWAY_APP_ID> --query id -o tsv)
az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP/appRoleAssignedTo" \
  --query "value[].{principal:principalDisplayName,type:principalType,roleId:appRoleId}" -o json

# Tier group membership
az ad group member list --group <TIER_GROUP_OBJECT_ID> \
  --query "[].{name:displayName,upn:userPrincipalName}" -o json
```

Inspect a token you already hold, to confirm the claims really are what you expect:

```bash
az account get-access-token --scope "api://<GATEWAY_APP_ID>/access_as_user" --query accessToken -o tsv \
  | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | python -m json.tool
```

Check `aud`, `iss`, `sub`, and that `groups` is present and contains the expected
object IDs. If `_claim_names` appears instead of `groups`, you have hit the overage
trap described above.

## Creating the objects (for the runbook — do not execute)

```bash
# App registration
az ad app create --display-name "<GATEWAY_APP_NAME>" --sign-in-audience AzureADMyOrg
APP_ID=$(az ad app list --display-name "<GATEWAY_APP_NAME>" --query "[0].appId" -o tsv)
OBJ_ID=$(az ad app list --display-name "<GATEWAY_APP_NAME>" --query "[0].id" -o tsv)

az ad app update --id "$APP_ID" --identifier-uris "api://$APP_ID"
az ad sp create --id "$APP_ID"

# Scope, app roles, groups claim and pre-authorization all live in one PATCH
az rest --method PATCH \
  --url "https://graph.microsoft.com/v1.0/applications/$OBJ_ID" \
  --headers "Content-Type=application/json" \
  --body @app-registration.json

# Tier groups
az ad group create --display-name "claude-tier-gold" --mail-nickname "claude-tier-gold"

# Assign a group to an app role (requires Entra ID P1/P2)
SP=$(az ad sp show --id "$APP_ID" --query id -o tsv)
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP/appRoleAssignedTo" \
  --headers "Content-Type=application/json" \
  --body '{"principalId":"<GROUP_OBJECT_ID>","resourceId":"'"$SP"'","appRoleId":"<GOLD_ROLE_ID>"}'
```
