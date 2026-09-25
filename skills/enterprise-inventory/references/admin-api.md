# Anthropic Admin API reference

Reference for the `enterprise-inventory` skill. Read-only extraction only — every
call below is a `GET`.

## Base and headers

```
https://api.anthropic.com/v1/organizations/...

x-api-key: sk-ant-admin01-...
anthropic-version: 2023-06-01
```

Accepted credentials: an Admin API key (`sk-ant-admin01-` prefix), an OAuth token
with the `org:admin` scope, or a personal/service-account key that is **not** scoped
to a single workspace. Workspace-scoped keys are rejected. Admin keys are created in
the Console by an Owner or Admin; there is no API to mint one. The Admin API is not
available to individual (non-organization) accounts.

## Endpoints

| Purpose | Endpoint |
| --- | --- |
| Organization identity | `GET /me` |
| List users | `GET /users?limit=100` |
| Get user | `GET /users/{user_id}` |
| List invites | `GET /invites` |
| List workspaces | `GET /workspaces?limit=100&include_archived=false` |
| Get workspace | `GET /workspaces/{workspace_id}` |
| Workspace members | `GET /workspaces/{workspace_id}/members?limit=100` |
| List API keys | `GET /api_keys?limit=100` |
| Org rate limits | `GET /rate_limits` |
| Workspace rate limits | `GET /workspaces/{workspace_id}/rate_limits` |
| Usage report | `GET /usage_report/messages` |
| Cost report | `GET /cost_report` |
| Claude Code usage | `GET /usage_report/claude_code` |

`GET /me` returns `{"id": "<uuid>", "type": "organization", "name": "..."}`. The id is
a plain UUID with no prefix.

## Identifiers and enums

- User IDs are `user_`-prefixed. Workspace IDs are `wrkspc_`-prefixed.
- Organization roles: `user`, `claude_code_user`, `developer`, `billing`, `admin`.
  `owner` exists but cannot be assigned or removed through the API.
- Workspace roles: `workspace_user`, `workspace_limited_developer`,
  `workspace_developer`, `workspace_admin`, `workspace_billing`.
- An organization is capped at 100 workspaces by default. Archiving is irreversible
  and there is no delete; archived workspaces carry `archived_at`.

## Pagination — two different models

**List/CRUD endpoints** use an ID cursor:

```
?limit=100&after_id=<last_id>
→ { "data": [...], "has_more": true, "first_id": "...", "last_id": "..." }
```

Loop while `has_more`, passing the previous `last_id` as `after_id`.

**Report endpoints** use an opaque cursor:

```
?limit=100&page=<next_page>
→ { "data": [...], "has_more": true, "next_page": "..." }
```

The two are not interchangeable. Paginating a report with `after_id` silently returns
the first page forever.

## Usage and cost reports

```
GET /usage_report/messages
      ?starting_at=2026-06-01T00:00:00Z
      &ending_at=2026-08-31T23:59:59Z
      &bucket_width=1d
      &group_by[]=workspace_id
      &group_by[]=model
```

`bucket_width` accepts `1m`, `1h`, `1d`. Available `group_by` dimensions include
`api_key`, `workspace_id`, `model`, `service_tier` and `context_window`.

`GET /cost_report` takes the same time window and bucket parameters and reports spend.

For quota sizing you want **peak daily tokens per workspace**, not the average. Bucket
at `1d`, group by `workspace_id`, and take the maximum across the window.

## Limits: what is readable

| | Readable via API | Writable via API |
| --- | --- | --- |
| Org rate limits | yes — `GET /rate_limits` | no |
| Workspace rate limits | yes — `GET /workspaces/{id}/rate_limits` | no |
| Org spend limits | **no** | no |
| Workspace spend limits | **no** | no |

Spend limits are Console-UI only: Settings → Workspaces → Spend limits, and
Settings → Billing. They must be transcribed by a human. Mark them `source: manual`
in the migration profile so a reviewer can distinguish observed from transcribed
values.

Organization rate limits are tiered (Evaluation, Start, Build, Scale, Custom) with
per-model RPM / input-tokens-per-minute / output-tokens-per-minute allowances. Live
values also surface on every inference response as `anthropic-ratelimit-*` headers.

## Claude Enterprise (claude.ai) differences

Claude Enterprise shares the `/v1/organizations/` members and invites surface, but:

- It has **no** workspaces, API keys or rate-limits endpoints.
- It adds Enterprise-only RBAC group/role endpoints and per-member spend limits.
- Usage, cost and Claude Code data come from a separate **Claude Enterprise Analytics
  API** under `/v1/organizations/analytics/`, which requires its own Analytics API
  key — an Admin key will not authenticate against it.

## The cutover-ordering constraint

The Claude Code Analytics API **excludes** usage routed through Microsoft Foundry,
Bedrock, Vertex, and Claude Platform on AWS. Post-migration, Anthropic-side analytics
go quiet; token accounting moves to APIM metrics and OpenTelemetry.

The practical consequence: capture the baseline before cutover. There is no way to
reconstruct it afterwards.
