# edge (prod)

The public edge for developmentfinance.org, in prod only. Cloudflare proxies the zone's records to a global external Application Load Balancer, which routes every request through a serverless network endpoint group to the `dfo-prod-website` Cloud Run service. The `.tf` files are symlinks to `infra/stacks/edge`. This directory holds prod's backend, tfvars, and lock file.

The load balancer listens on 443 only. Cloudflare's Always Use HTTPS redirects plain HTTP at the edge, and Cloudflare reaches the origin over HTTPS.

## Origin lock

The Cloud Armor policy `dfo-prod-edge` on the backend service denies every request with a 403 unless it carries the header `x-dfo-edge-auth` set to a shared secret. Cloudflare's Transform Rule adds that header to each request it forwards, so only traffic that passed Cloudflare's rate limit and Access rules reaches the website. A Cloudflare zone of someone else's, pointed at the load balancer's address, lacks the header and gets the 403.

The secret is a `random_password` in `origin_secret.tf`, held in the stack's state in the private state bucket. Anyone with `compute.securityPolicies.get` on `prod-fin-observatory` can also read it from the policy's rule expression. Whoever holds the value can reach the origin through a Cloudflare zone of their own, so rotate it if it leaks.

To send a request to the load balancer directly, bypassing Cloudflare, with the secret:

```bash
curl --resolve developmentfinance.org:443:"$(terraform output -raw lb_ipv4)" \
  -H "x-dfo-edge-auth: $(terraform output -raw origin_auth_header_value)" \
  https://developmentfinance.org/
```

## Rotating the origin secret

Bump `origin_auth_rotation` in `infra/stacks/edge/origin_secret.tf` and merge. The apply replaces the `random_password`, then rewrites the Cloud Armor rule and the Cloudflare Transform Rule in the same run. Between those two writes the origin expects one value and Cloudflare sends the other, so requests fail with a 403 for a few seconds. Rotate at a quiet hour.

## Certificate

Certificate Manager issues one managed certificate for `developmentfinance.org` and `*.developmentfinance.org`, which covers `www` and `preview`. The certificate map holds a single `PRIMARY` entry, so the proxy serves that certificate for any SNI. Cloudflare's SSL mode is Full (strict), so it validates this certificate on every request to the origin.

Google proves control of the domain through a DNS authorization of type `PER_PROJECT_RECORD`. Its CNAME lives at `_acme-challenge_<suffix>.developmentfinance.org`, given by the `dns_authorization_record` output. The stack creates it in Cloudflare, unproxied, in `cloudflare_dns.tf`. The fixed-record type would put the CNAME at `_acme-challenge.developmentfinance.org`, where Cloudflare's Universal SSL serves its own ACME TXT records, and Google requires the CNAME to be the only record at its name.

The certificate stays in `PROVISIONING` until Google sees the CNAME. Check that it is `ACTIVE` before sending traffic to the load balancer:

```bash
gcloud certificate-manager certificates describe dfo-prod-edge \
  --project prod-fin-observatory --format 'value(managed.state)'
```

## Cloudflare

The stack manages these parts of the `developmentfinance.org` zone. The Logpush job and the `http_log_custom_fields` ruleset belong to the edge-logs stack. The token reaches the zone by the id in `cloudflare_zone_id`, so it needs no Zone Read lookup.

- DNS. The apex and `www` A records are imported. Both point at the holding page (`35.186.240.63`, the `devfinance-redirect-ip` load balancer in `one-data-commons`) while `serve_from_lb` is false, and at the load balancer once it is true. `preview.developmentfinance.org` and `mcp.developmentfinance.org` point at the load balancer. The three SES DKIM CNAMEs, which ONE published for mail from `studio@developmentfinance.org`, are imported and must stay DNS only. `_dmarc` publishes `v=DMARC1; p=none`, which asks receivers for no policy and no reports. The `MS=` and `_gh-developmentfinanceobservatory-o` TXT records stay unmanaged.
- Origin auth, phase `http_request_late_transform`. Sets the origin secret header on requests to the apex, preview, and MCP hosts.
- Redirect, phase `http_request_dynamic_redirect`. Sends `www` to `https://developmentfinance.org` with a 301, keeping the path and query. On `mcp.developmentfinance.org`, every path that does not start with `/mcp` gets the same redirect, so `https://mcp.developmentfinance.org/mcp` serves the MCP endpoint and the host serves nothing else. The zone's existing empty ruleset in this phase is imported, because a zone holds one entrypoint ruleset per phase.
- Rate limit, phase `http_ratelimit`. Two rules, the Pro plan's limit, each counting per IP over 60 s and blocking for 10 minutes. An IP that sends more than `edge_studio_requests_per_minute` requests to a path starting `/api/v1/studio` or `/api/studio` is blocked from Studio. An IP that sends more than `edge_api_requests_per_minute` requests to any other path starting `/api/v1/`, `/api/search`, `/api/datasets`, or `/api/graph` is blocked from the data API. `/mcp` has no edge limit. Cloudflare counts per IP on this plan, and MCP connectors call from a few shared provider addresses, so a limit there would block all of a connector's users together. The harness caps `/mcp` tool calls per instance with `COMBINED_MCP_REQUESTS_PER_S` and `COMBINED_MCP_BURST`, set in `infra/stacks/ai/main.tf`.
- Cache, phase `http_request_cache_settings`, only while `edge_cache_enabled` is true, which needs the edge-logs stack's Logpush job first (see "Logpush"). One rule makes four kinds of path cache-eligible when the request carries no `Authorization` or `X-API-Key` header: a dataset file, `/api/datasets/spec_<id>/cv_<hex>/files/<digest>`, with nothing after the digest; a dataset manifest, exactly `/api/datasets/spec_<id>/cv_<hex>`; a derived frame's file, `/api/datasets/derived/ops_<id>/ocv_<hex>/files/<digest>`, with nothing after the digest; and the heads lookup, exactly `/api/datasets/heads?spec_id=<id>`, matched on the path alone with `eq`, so it is case-exact and each query string is its own cache entry. The origin sets `Cache-Control: public, max-age=300` on a 200 and `no-store` on a 400, so the edge holds a heads answer for 300 s and stores no error. All four match under `/api/v1/datasets/` too, since the SDK reads a manifest there and a file at the manifest's own `/api/datasets/` url, and reads a recipe's file at `/api/v1/datasets/derived/`. The website holds a derived frame's file for 300 s at the edge and 60 s in the browser, since a revocation cannot yet name the derived frames computed from the revoked version. The `/file` selector and every other path with a third segment stay uncached. Share slot data is not in the rule, since a share that is withdrawn has no purge path; the website serves it with its own `Cache-Control`. The rule sets no TTL. Cloudflare follows the website's `Cache-Control`, and stores nothing when a response has none or says `no-store`. A cross-origin request carries `Origin` and its response carries an `Access-Control-Allow-Origin` for that origin. Cloudflare's [default cache key](https://developers.cloudflare.com/cache/how-to/cache-keys/) always includes the `Origin` header unless a custom cache key excludes it, so each origin gets its own cached variant with the header the website sent for it, and the apex, `preview.developmentfinance.org`, prototype previews and localhost all get the cache. The stack sets no custom cache key, and the rule must not set one that excludes `Origin`. A request with an `Authorization` or `X-API-Key` header bypasses the cache, since the website accepts an API key in either and counts every keyed read against the key's account. Only GET is cache-eligible: Cloudflare would answer an eligible HEAD from a cached GET and fetch a cold one from the website as a GET ([cache behaviour](https://developers.cloudflare.com/cache/concepts/cache-behavior/)), and the Logpush job records GET only, so a HEAD goes uncached to the website. The expressions use `wildcard`, since the Pro plan has no regex. `wildcard` ignores case, so the rule also tests both prefixes case-sensitively with `starts_with`, the way the Logpush filter matches them, and a path in another case goes uncached to the website. `dataset_path_prefixes` in `infra/stacks/edge/cloudflare_rules.tf` and in `infra/stacks/edge-logs/cloudflare_logpush.tf` must list the same prefixes.
- Managed WAF, phase `http_request_firewall_managed`. The Cloudflare Managed Ruleset runs at its default actions. The OWASP Core Ruleset runs at paranoia level 1 with its anomaly rule set to log, so a request scoring 40 or more appears in Security Events with the action Log and still reaches the origin. Review those events before changing the action to block.
- Access on the preview host. A zone-scoped self-hosted application with an inline allow policy for `preview_access_email_domains`, plus any `preview_access_emails` (prod sets none), and a 24-hour session. It uses the account's Zero Trust organisation and identity providers, which the stack leaves alone. The preview host serves the production website, whose Better Auth origin is `BETTER_AUTH_URL` (the `website_url` tfvar). Sign-in and OAuth callbacks work only on that origin and fail on the preview host; browsing, search, downloads, and guest Studio work there.

A plan with the read-only token, as the `plan` environment runs in CI, prints `failed to make http request for the dry run ... 403` for the rulesets. This is expected, because Cloudflare's ruleset dry run needs write permission.

The first apply adopts the apex and `www` records and the redirect ruleset through the `import` blocks in `cloudflare_dns.tf` and `cloudflare_rules.tf`. Once state holds them, the blocks do nothing.

### Before the first apply of the cache rule

A zone holds one entrypoint ruleset per phase, so creating the cache ruleset fails when the zone already has one for `http_request_cache_settings`. List the zone's rulesets for that phase with a read-only call, using a token that has Cache Rules Read:

```bash
curl -sS "https://api.cloudflare.com/client/v4/zones/e837f8819d4b16dce14e17cbe6ba3716/rulesets" \
  -H "Authorization: Bearer $(security find-generic-password -s dfo-cloudflare-edge-plan -w)" |
  jq '.result[] | select(.phase == "http_request_cache_settings") | {id, name, kind, phase}'
```

An empty answer means the create works. When the call lists an entrypoint, uncomment the `import` block above `cloudflare_ruleset.cache` in `cloudflare_rules.tf`, whose address is `cloudflare_ruleset.cache[0]`, put the listed `id` in it, and make the resource's `name` and `kind` match the listed ones, since a change would replace the ruleset. The rules the entrypoint holds are replaced by this stack's rule on the first apply, so read them before applying. Comment the block out again once state holds the ruleset.

## Logpush

The `dataset-reads` Logpush job writes one line for every GET the edge handles on a dataset path, cache hits included, unsampled, to the telemetry stack's bucket. A read Cloudflare answers from its cache never reaches the website, so these lines are the only record of it. The job, its custom fields and its ownership challenge live in the edge-logs stack, since every Logpush API call needs Logs Write on the zone, reads included ([permissions](https://developers.cloudflare.com/logs/logpush/permissions/)). [`infra/dfo-prod/edge-logs/README.md`](../edge-logs/README.md) has the fields, the cost, the health checks and `scripts/check-edge-logpush.sh`.

`cloudflare_ruleset.cache` has a precondition that reads the zone's Logpush jobs through the `cloudflare_logpush_jobs` data source and fails unless exactly one job is named `dataset-reads` on `http_requests`, is enabled, reports a `last_complete`, the end of the newest period it has delivered, and reports no `last_error` or `error_message`. Cloudflare sets those two while the job is failing and clears them on its next successful push, so a job that delivered once and fails now also refuses the cache. The data source exists only while `edge_cache_enabled` and `edge_cache_logpush_check` are both true, and both of the provider's Logpush data sources accept only Logs Write ([`cloudflare_logpush_jobs`](https://registry.terraform.io/providers/cloudflare/cloudflare/5.27.0/docs/data-sources/logpush_jobs)). `edge_cache_logpush_check` defaults to true, so every apply checks the job. `plan-prod.yml` sets `TF_VAR_edge_cache_logpush_check=false` on pull-request plans, which use the read-only token and apply nothing, so they make no Logpush call and skip the precondition. A local plan with the plan token needs the same export once the cache is on. While `edge_cache_enabled` is false, no plan reads Logpush at all.

### Apply order for the cache

Each step is its own merge to main:

1. Apply the telemetry stack, which creates the bucket.
2. Set `edge_logpush_bucket` in `infra/dfo-prod/edge-logs/env.auto.tfvars` and apply the edge-logs stack, which creates the job.
3. Send a read and run `scripts/check-edge-logpush.sh` until it passes.
4. Confirm that the edge extract Job `dfo-prod-analytics-edge` exists and runs on its hourly trigger, so the edge reads reach `edge_export.deliveries` in BigQuery. The telemetry stack creates it while `analytics_jobs_enabled` is on in `infra/dfo-prod/telemetry/env.auto.tfvars` ("Analytics jobs" in `infra/dfo-prod/telemetry/README.md`). Its latest scheduled execution must have succeeded: `gcloud run jobs executions list --job=dfo-prod-analytics-edge --region=europe-west1 --project=prod-fin-observatory --limit=3`. Without it, every read the cache answers stays in the bucket and expires there after three days.
5. Set `edge_cache_enabled = true` in `infra/dfo-prod/edge/env.auto.tfvars` and apply this stack. Then run `scripts/check-edge-cache.sh` as "Checking the cache after an apply" describes, `scripts/check-edge-logpush.sh` again, which should now count `hit` lines, and the BigQuery check in "Confirming that a miss and a hit both reach BigQuery". The cache is live only when that check passes.

The edge-logs README has the detail of each step. To turn the cache off, set `edge_cache_enabled` to false and apply; the ruleset is deleted. Remove the job only after that.

## Revoking a dataset version

A revoked version answers 410 at the API, but Cloudflare keeps serving the copies it holds until they expire, up to a year for a pinned file. The website sets `Cache-Tag: <content_version>` on each cacheable dataset response, under both prefixes and every id that serves the version, so one purge by tag removes them all. Cloudflare's [purge by tag](https://developers.cloudflare.com/cache/how-to/purge-cache/purge-by-tags/) removes "all content containing that cache-tag" but does not name `Origin` variants, so the post-purge check below confirms that each variant answers `MISS` again. Cloudflare strips `Cache-Tag` before the response reaches the visitor.

After the revocation is written in the Datasets database, list its content version and the content version of every version derived from it, since revoking a base version withdraws them too. A frame DFO computed from a revoked version, under `/datasets/derived/`, has no list yet (DevelopmentFinanceObservatory/apis#379), so its file stays at the edge until its 300 s expire. Purge the dataset versions, at most 100 tags per call:

```bash
CLOUDFLARE_PURGE_API_TOKEN="$(security find-generic-password -s dfo-cloudflare-edge-purge -w)"
curl -sS https://api.cloudflare.com/client/v4/zones/e837f8819d4b16dce14e17cbe6ba3716/purge_cache \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $CLOUDFLARE_PURGE_API_TOKEN" \
  -d '{"tags": ["cv_<hex>", "cv_<hex of a derived version>"]}'
```

The call answers `"success": true` once the purge is queued. Then run `scripts/check-edge-cache.sh --revoked`, which reads each variant of a revoked file and its manifest, and the v1 manifest, once, and passes only when every answer is 410 and its `cf-cache-status` is neither `HIT` nor `STALE`:

```bash
scripts/check-edge-cache.sh --revoked \
  /api/datasets/spec_<id>/cv_<hex>/files/<digest> \
  '/api/datasets/spec_<id>/cv_<hex>/file?format=csv'
```

Do not use `--after-purge` here: it expects the 200 a live version answers and fails on a 410. A purge cannot reach browser caches. A pinned file's `max-age=3600` means a returning visitor's browser can show the revoked file for up to an hour.

## Checking the cache after an apply

`scripts/check-edge-cache.sh` sends GETs and one HEAD. For a dataset file and for its manifest under `/api/datasets/`, it reads three variants twice each, with no `Origin`, with `Origin: https://developmentfinance.org`, and with `Origin: https://preview.developmentfinance.org`, and expects `MISS` then `HIT` for each variant, with an `Access-Control-Allow-Origin` equal to the request's `Origin` (absent when there is none). It reads the manifest under `/api/v1/datasets/` twice with no `Origin` and expects `MISS` then `HIT`, reads it with an `Authorization` header and expects `BYPASS` or `DYNAMIC`, reads it with an `X-API-Key` header and expects `BYPASS` or `DYNAMIC` with HTTP status 200 or 401 (the placeholder value does not start with `dfo_`, so the website reads it as no key and answers 200; a refused key answers 401), sends it a HEAD and expects `DYNAMIC`, reads the `/file` selector and expects `DYNAMIC`, and fails if any response shows `Cache-Tag`. It exits 2 on a usage error. Take the file path from a manifest's artifact `url`, for a version no one has read through the edge since its last purge:

```bash
scripts/check-edge-cache.sh \
  /api/datasets/spec_<id>/cv_<hex>/files/<digest> \
  '/api/datasets/spec_<id>/cv_<hex>/file?format=csv'
```

After purging a live version's tag, `--after-purge` skips the `HIT` reads, reads each file and manifest variant once, and expects `MISS` for every one. Run it only on a version the first run has already filled. After a revocation, use `--revoked` instead ("Revoking a dataset version").

```bash
scripts/check-edge-cache.sh --after-purge \
  /api/datasets/spec_<id>/cv_<hex>/files/<digest> \
  '/api/datasets/spec_<id>/cv_<hex>/file?format=csv'
```

`scripts/check-edge-cache.test.sh` tests the script against a stub `curl`.

### Confirming that a miss and a hit both reach BigQuery

The cache stays on only after one request has been counted as an origin miss and again as an edge hit in BigQuery. `check-edge-logpush.sh` stops at the bucket, so this check follows the data into BigQuery. It needs the cache on, since a hit cannot exist before it, so it runs right after the apply in step 5 of "Apply order for the cache". Activation waits on it: until it passes, nothing treats the cache as live, and a failure means setting `edge_cache_enabled` back to false and applying. The batches in the bucket expire three days after they are written, so the load into BigQuery and this query must both finish inside that window, or the hit row is gone before it can be checked.

1. Run `scripts/check-edge-cache.sh` on a version no one has read since its last purge. Its first read of the file in each variant is an origin miss and its second an edge hit. Note the UTC time before the first read and after the last, and the `spec_<id>` and `cv_<hex>` of the file path.
2. Wait for the next hourly run of the `dfo-prod-analytics-edge` Cloud Run Job (`python -m dfo_analytics.extract.edge`, at minute 5), which loads the Logpush batches into `prod-fin-observatory.edge_export.deliveries` (one row per GET, keyed by `ray_id`). Then run the query below with `<spec_id>`, `<content_version>`, `<start>` and `<end>` set from step 1. The first branch counts edge rows by `cache_status` and whether they carry an `origin_status`. The second counts the dfo-apis delivery lines (`datasets_api.delivery`) in `dfo_logs._AllLogs` for the `files` door, which serves `/files/<digest>`. Both branches count file reads alone, since `check-edge-cache.sh` also reads the manifest, which logs its own delivery line under the `snapshot` door, and the `/file` selector, which logs one under `file_selector`. Both filter on their partition column.

```bash
bq query --project_id=prod-fin-observatory --location=EU --use_legacy_sql=false \
  "SELECT 'edge' AS source, cache_status AS kind, origin_status IS NOT NULL AS has_origin_status, COUNT(*) AS n
   FROM \`prod-fin-observatory.edge_export.deliveries\`
   WHERE edge_started_at BETWEEN TIMESTAMP '<start>' AND TIMESTAMP '<end>'
     AND spec_id = '<spec_id>' AND content_version = '<content_version>' AND path_kind = 'file'
   GROUP BY kind, has_origin_status
   UNION ALL
   SELECT 'dfo_apis_delivery', 'delivery_line', NULL, COUNT(*)
   FROM \`prod-fin-observatory.dfo_logs._AllLogs\`
   WHERE timestamp BETWEEN TIMESTAMP '<start>' AND TIMESTAMP '<end>'
     AND JSON_VALUE(json_payload, '\$.logger') = 'datasets_api.delivery'
     AND JSON_VALUE(json_payload, '\$.door') = 'files'
     AND JSON_VALUE(json_payload, '\$.spec_id') = '<spec_id>'
     AND JSON_VALUE(json_payload, '\$.content_version') = '<content_version>'"
```

Expected, for the file reads of one `check-edge-cache.sh` run (three variants, each read twice): an `edge` row with `kind` `miss` and `has_origin_status` true, `n` 3; an `edge` row with `kind` `hit` and `has_origin_status` false, `n` 3; and a `dfo_apis_delivery` row with `n` 3, one `files` delivery line for each miss and none for the hits. A missing `miss` or `hit` row means the Logpush row did not reach BigQuery, so check the extract job's latest run. A delivery count below the miss count means a miss did not reach dfo-apis' log. A count above it means a hit did reach the origin. Any of these fails the check.

## Counting dataset reads

The website's request log misses every read that Cloudflare answers from its cache, which is most of what the cache rule exists to serve. `scripts/edge-usage.sh <start_date> <end_date>` estimates them at the edge. It queries the GraphQL Analytics API's `httpRequestsAdaptiveGroups` for GET requests to the dataset paths under both prefixes, and prints a tab-separated table of UTC day, prefix, kind (`file`, `derived_file`, `manifest`, `heads`, or `selector`), cache status, requests, bytes (`edgeResponseBytes`) and the `sampled` interval (`avg { sampleInterval }`; 1 means unsampled, 10 means one request in ten was sampled, and folded rows show the request-weighted mean). `EDGE_USAGE_BY_REFERER=1` adds the referring host as a column through the `clientRefererHost` dimension. Cloudflare's pages list `clientRequestPath` ([example](https://developers.cloudflare.com/analytics/graphql-api/tutorials/end-customer-analytics/)) and the 31-day minimum retention of adaptive datasets ([limits](https://developers.cloudflare.com/analytics/graphql-api/limits/)) but not each dataset's dimensions, so confirm `cacheStatus` and `clientRefererHost` by [introspection](https://developers.cloudflare.com/analytics/graphql-api/features/discovery/introspection/) with the analytics token before relying on the output; Cloudflare answers an unknown field with an error, which the script prints. These figures are sampled estimates; the Logpush lines ("Logpush") are the unsampled record of the same reads. `httpRequestsAdaptiveGroups` is an adaptive dataset, so Cloudflare samples it at a rate the caller cannot set ([sampling](https://developers.cloudflare.com/analytics/graphql-api/sampling/)) and scales the counts and bytes up from the sample. Use them for the cache hit share and the bytes served from the edge. They are a separate source from the analytics repo's dataset uses, which count dfo-apis delivery lines, and are never added to them. The query follows Cloudflare's [colo migration guide](https://developers.cloudflare.com/analytics/graphql-api/migration-guides/zone-analytics-colos/), which requests `sum { edgeResponseBytes }` and `avg { sampleInterval }` on this dataset. The script exits 1 when an answer reaches the 10,000-row limit, so query a shorter range.

The token is read-only: Analytics Read on the zone, in the macOS keychain service `dfo-cloudflare-edge-analytics`, or exported as `CLOUDFLARE_ANALYTICS_API_TOKEN`. `scripts/edge-usage.test.sh` tests the script against a stub `curl`.

## Apply order

Turning the cache on follows the order in "Apply order for the cache": telemetry, then edge-logs, then `scripts/check-edge-logpush.sh`, then a check that the `dfo-prod-analytics-edge` extract Job runs, then `edge_cache_enabled = true` here. All three stacks are consumers in `apply.yml` and run side by side, so each step merges only after the one before it has applied. Edge also applies after `foundation`, which grants the applier the load balancer, Cloud Armor, and Certificate Manager roles and lets it write this stack's state, and after `website`, whose Cloud Run service the endpoint group names. The stack enables `certificatemanager.googleapis.com` itself. The first apply can fail with `SERVICE_DISABLED` on the Certificate Manager resources while the API propagates. Recover with a `workflow_dispatch` of `apply.yml` with `stack=edge`. The same dispatch recovers an apply where the `apis` producer tier failed and skipped edge.

## Made by hand first

- A local backend init, `just ENV=dfo-prod STACK=edge bootstrap`, once `foundation` has applied.
- The Cloudflare API token, zone-scoped to developmentfinance.org. CI reads it from the `CLOUDFLARE_API_TOKEN` secret in the `production` (edit) and `plan` (read) environments. Locally, export it from the macOS keychain service `dfo-cloudflare-edge-apply` or `dfo-cloudflare-edge-plan` as `CLOUDFLARE_API_TOKEN`. The provider reads only that variable. The apply token needs Cache Rules Edit permission on the zone for the cache ruleset, and the plan token needs Cache Rules Read. The apply token also needs Logs Write on the zone, for the edge-logs stack, which uses the same `production` secret, and for the cache rule's precondition here. The plan token holds no Logs permission: no pull-request plan reads Logpush ("Logpush").
- The purge token, zone-scoped to developmentfinance.org with the Cache Purge permission and nothing else, for the purge in "Revoking a dataset version". Terraform does not read it. It lives in the macOS keychain service `dfo-cloudflare-edge-purge` of whoever writes revocations. The stack's own tokens are zone-scoped and cannot create tokens, so it is made in the Cloudflare dashboard.
- The analytics token, zone-scoped to developmentfinance.org with Analytics Read and nothing else, for `scripts/edge-usage.sh`. Terraform does not read it. It lives in the macOS keychain service `dfo-cloudflare-edge-analytics`.
