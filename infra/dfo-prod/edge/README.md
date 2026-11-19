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

The stack manages these parts of the `developmentfinance.org` zone. The token reaches the zone by the id in `cloudflare_zone_id`, so it needs no Zone Read lookup.

- DNS. The apex and `www` A records are imported. Both point at the holding page (`35.186.240.63`, the `devfinance-redirect-ip` load balancer in `one-data-commons`) while `serve_from_lb` is false, and at the load balancer once it is true. `preview.developmentfinance.org` and `mcp.developmentfinance.org` point at the load balancer. The three SES DKIM CNAMEs, which ONE published for mail from `studio@developmentfinance.org`, are imported and must stay DNS only. `_dmarc` publishes `v=DMARC1; p=none`, which asks receivers for no policy and no reports. The `MS=` and `_gh-developmentfinanceobservatory-o` TXT records stay unmanaged.
- Origin auth, phase `http_request_late_transform`. Sets the origin secret header on requests to the apex, preview, and MCP hosts.
- Redirect, phase `http_request_dynamic_redirect`. Sends `www` to `https://developmentfinance.org` with a 301, keeping the path and query. On `mcp.developmentfinance.org`, every path that does not start with `/mcp` gets the same redirect, so `https://mcp.developmentfinance.org/mcp` serves the MCP endpoint and the host serves nothing else. The zone's existing empty ruleset in this phase is imported, because a zone holds one entrypoint ruleset per phase.
- Rate limit, phase `http_ratelimit`. Two rules, the Pro plan's limit, each counting per IP over 60 s and blocking for 10 minutes. An IP that sends more than `edge_studio_requests_per_minute` requests to a path starting `/api/v1/studio` or `/api/studio` is blocked from Studio. An IP that sends more than `edge_api_requests_per_minute` requests to any other path starting `/api/v1/`, `/api/search`, `/api/datasets`, or `/api/graph` is blocked from the data API. `/mcp` has no edge limit. Cloudflare counts per IP on this plan, and MCP connectors call from a few shared provider addresses, so a limit there would block all of a connector's users together. The harness caps `/mcp` tool calls per instance with `COMBINED_MCP_REQUESTS_PER_S` and `COMBINED_MCP_BURST`, set in `infra/stacks/ai/main.tf`.
- Cache, phase `http_request_cache_settings`, only while `edge_cache_enabled` is true, which needs the Logpush job first (see "Logpush"). One rule makes two kinds of path cache-eligible when the request carries no `Authorization` header: a dataset file, `/api/datasets/spec_<id>/cv_<hex>/files/<digest>`, with nothing after the digest; and a dataset manifest, exactly `/api/datasets/spec_<id>/cv_<hex>`. Both match under `/api/v1/datasets/` too, since the SDK reads a manifest there and a file at the manifest's own `/api/datasets/` url. The `/file` selector and every other path with a third segment stay uncached. Share slot data is not in the rule, since a share that is withdrawn has no purge path; the website serves it with its own `Cache-Control`. The rule sets no TTL. Cloudflare follows the website's `Cache-Control`, and stores nothing when a response has none or says `no-store`. A cross-origin request carries `Origin` and its response carries an `Access-Control-Allow-Origin` for that origin. Cloudflare's [default cache key](https://developers.cloudflare.com/cache/how-to/cache-keys/) always includes the `Origin` header unless a custom cache key excludes it, so each origin gets its own cached variant with the header the website sent for it, and the apex, `preview.developmentfinance.org`, prototype previews and localhost all get the cache. The stack sets no custom cache key, and the rule must not set one that excludes `Origin`. A request with an `Authorization` header bypasses the cache. The expressions use `wildcard`, since the Pro plan has no regex. `wildcard` ignores case, so the rule also tests both prefixes case-sensitively with `starts_with`, the way the Logpush filter matches them, and a path in another case goes uncached to the website.
- Log custom fields, phase `http_log_custom_fields`, only while `edge_logpush_bucket` is set. Adds the `origin` and `x-dfo-client` request headers to each `http_requests` Logpush line, under `RequestHeaders`.
- Logpush job `dataset-reads`, only while `edge_logpush_bucket` is set. See "Logpush".
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

Cloudflare Logpush writes one line for every GET the edge handles on a path starting `/api/datasets/` or `/api/v1/datasets/`, from any host, cache hits included, with no sampling (`sample_rate` 1). A read Cloudflare answers from its cache never reaches the website, so these lines are the only record of it. The job is `cloudflare_logpush_job.dataset_reads` in `infra/stacks/edge/cloudflare_logpush.tf`, on the zone's [`http_requests` dataset](https://developers.cloudflare.com/logs/logpush/logpush-job/datasets/zone/http_requests/).

It writes gzipped NDJSON batches named `<start>_<end>_<hash>.log.gz` to `gs://dfo-prod-edge-logs-prod-fin-observatory/http_requests/<YYYYMMDD>/`, a bucket the telemetry stack owns (`infra/stacks/telemetry/edge_logs.tf`). The bucket is in the EU multi-region with uniform access and public access prevention enforced. Cloudflare's `logpush@cloudflare-data.iam.gserviceaccount.com` holds `roles/storage.objectAdmin` on it, the role the [GCS destination page](https://developers.cloudflare.com/logs/logpush/logpush-job/enable-destinations/google-cloud-storage/) asks for. The lines carry raw client IPs, so a lifecycle rule deletes each batch one day after it is written, and soft delete is off. GCS acts on a lifecycle rule [asynchronously](https://cloud.google.com/storage/docs/lifecycle#behavior), so a batch can last up to about two days. The applier and the project owners can read the batches. The planner's object-read grant on the bucket covers only the `.txt` ownership challenge files.

Each line has these fields, in this order, with timestamps in RFC 3339 ([output options](https://developers.cloudflare.com/logs/logpush/logpush-job/log-output-options/)). `RequestHeaders` holds the two headers the custom fields rule names, as the request sent them ([custom fields](https://developers.cloudflare.com/logs/logpush/logpush-job/custom-fields/)). `OriginResponseStatus` is 0 when the edge answered without the origin.

```json
{"EdgeStartTimestamp":"2026-11-19T11:30:01Z","RayID":"8e3f2a1b4c5d6e7f","ClientRequestMethod":"GET","ClientRequestHost":"developmentfinance.org","ClientRequestPath":"/api/datasets/spec_<id>/cv_<hex>/files/<digest>","ClientRequestReferer":"https://developmentfinance.org/","ClientRequestUserAgent":"Mozilla/5.0 ...","ClientIP":"192.0.2.1","ClientCountry":"gb","CacheCacheStatus":"hit","EdgeResponseStatus":200,"EdgeResponseBytes":48213,"OriginResponseStatus":0,"RequestHeaders":{"origin":"https://developmentfinance.org","x-dfo-client":"<client>"}}
```

`ClientRequestPath` has no query string. The `/file` selector is the only dataset read with one, and it is never cached, so the website's request log carries its format.

The filter is a [Logpush filter](https://developers.cloudflare.com/logs/logpush/logpush-job/filters/): `ClientRequestMethod` `eq` `GET`, and `ClientRequestPath` `startsWith` either prefix. Its operators are case-sensitive, so the cache rule repeats the same prefix test, and nothing the cache serves falls outside the filter.

Cost: Logpush to an external destination such as GCS includes 25 GB a month per Cloudflare account, then $0.10 per GB, counted on uncompressed delivered bytes ([pricing](https://developers.cloudflare.com/logs/logpush/pricing/)). The allowance covers every zone in ONE's account, so any other Logpush job there draws on it too.

Health: Logpush cannot backfill. A period when the job is disabled or failing is lost for good ([Logpush](https://developers.cloudflare.com/logs/logpush/)). Cloudflare's only Logpush notification, Failing Logpush Job Disabled (`failing_logpush_job_disabled_alert` in `cloudflare_notification_policy`), is listed for Enterprise plans ([available notifications](https://developers.cloudflare.com/notifications/notification-available/)) and is account-scoped, which this stack's zone token cannot write, so the stack does not create it. The zone's Logpush page has a Health tab with 30 days of upload results ([health dashboards](https://developers.cloudflare.com/logs/logpush/logpush-health/)). Run `scripts/check-edge-logpush.sh` after every edge apply and whenever the counts look low.

### Checking the feed

`scripts/check-edge-logpush.sh <bucket>` reads with `gcloud storage` only. It reads the batches that end in the last hour, counts the lines on the two dataset prefixes whose `EdgeStartTimestamp` falls in that hour, and prints them by `CacheCacheStatus`. It exits 1 when there are none, when a line lacks `CacheCacheStatus` or `ClientIP`, or when a day directory older than two days holds anything but the ownership challenge file, and 2 on a usage error. It needs `storage.objects.list` and `get` on the bucket, which the applier and the project owners hold. An idle hour has no lines, so send one read first:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://developmentfinance.org/api/v1/datasets/spec_<id>/cv_<hex>
scripts/check-edge-logpush.sh dfo-prod-edge-logs-prod-fin-observatory
```

`scripts/check-edge-logpush.test.sh` tests the script against a stub `gcloud`.

### Turning the job and the cache on

The cache rule cannot exist without the job. `edge_cache_enabled` defaults to false, and `cloudflare_ruleset.cache` has a precondition that fails unless `cloudflare_logpush_job.dataset_reads` exists, is enabled, and reports a `last_complete`, the end of the newest period it has delivered. A job created in the same apply has no `last_complete` yet, so the cache waits for a later apply.

1. Apply the telemetry stack, which creates the bucket and the Logpush grant. Its `edge_logs_bucket` output is the bucket name.
2. Before the first apply with the bucket set, list the zone's rulesets for `http_log_custom_fields`, as "Before the first apply of the cache rule" shows for the cache phase. When an entrypoint exists, add an `import` block for `cloudflare_ruleset.log_custom_fields[0]` with its id and make the `name` and `kind` match it.
3. Set `edge_logpush_bucket` in `infra/dfo-prod/edge/env.auto.tfvars` to that name and apply the edge stack. The apply creates the custom fields rule, asks Cloudflare for an ownership challenge, which Cloudflare writes to the bucket as `ownership-challenge-<random>.txt`, reads the token from that file, and creates the job with it ([ownership challenge](https://developers.cloudflare.com/logs/logpush/logpush-job/logpush-ownership-challenge/)). Leave the challenge file in place: every plan reads it, and the bucket's delete rule matches only `.log.gz`.
4. Send a read and run `scripts/check-edge-logpush.sh` until it passes.
5. Set `edge_cache_enabled = true` and apply. Then run `scripts/check-edge-cache.sh` as "Checking the cache after an apply" describes, and `scripts/check-edge-logpush.sh` again, which should now count `hit` lines.

To turn the cache off, set `edge_cache_enabled` to false and apply; the ruleset is deleted. Remove the job only after the cache is off: with the cache on, unsetting `edge_logpush_bucket` fails the precondition.

## Revoking a dataset version

A revoked version answers 410 at the API, but Cloudflare keeps serving the copies it holds until they expire, up to a year for a pinned file. The website sets `Cache-Tag: <content_version>` on each cacheable dataset response, under both prefixes and every id that serves the version, so one purge by tag removes them all. Cloudflare's [purge by tag](https://developers.cloudflare.com/cache/how-to/purge-cache/purge-by-tags/) removes "all content containing that cache-tag" but does not name `Origin` variants, so the post-purge check below confirms that each variant answers `MISS` again. Cloudflare strips `Cache-Tag` before the response reaches the visitor.

After the revocation is written in the Datasets database, list its content version and the content version of every version derived from it, since revoking a base version withdraws them too. Purge them, at most 100 tags per call:

```bash
CLOUDFLARE_PURGE_API_TOKEN="$(security find-generic-password -s dfo-cloudflare-edge-purge -w)"
curl -sS https://api.cloudflare.com/client/v4/zones/e837f8819d4b16dce14e17cbe6ba3716/purge_cache \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $CLOUDFLARE_PURGE_API_TOKEN" \
  -d '{"tags": ["cv_<hex>", "cv_<hex of a derived version>"]}'
```

The call answers `"success": true` once the purge is queued, and the next read of each purged path shows `cf-cache-status: MISS` and the API's 410. A purge cannot reach browser caches. A pinned file's `max-age=3600` means a returning visitor's browser can show the revoked file for up to an hour.

## Checking the cache after an apply

`scripts/check-edge-cache.sh` sends GETs only. For a dataset file and for its manifest under `/api/datasets/`, it reads three variants twice each, with no `Origin`, with `Origin: https://developmentfinance.org`, and with `Origin: https://preview.developmentfinance.org`, and expects `MISS` then `HIT` for each variant, with an `Access-Control-Allow-Origin` equal to the request's `Origin` (absent when there is none). It reads the manifest under `/api/v1/datasets/` twice with no `Origin` and expects `MISS` then `HIT`, reads it with an `Authorization` header and expects `BYPASS` or `DYNAMIC`, reads the `/file` selector and expects `DYNAMIC`, and fails if any response shows `Cache-Tag`. It exits 2 on a usage error. Take the file path from a manifest's artifact `url`, for a version no one has read through the edge since its last purge:

```bash
scripts/check-edge-cache.sh \
  /api/datasets/spec_<id>/cv_<hex>/files/<digest> \
  '/api/datasets/spec_<id>/cv_<hex>/file?format=csv'
```

After purging the version's tag as in "Revoking a dataset version", `--after-purge` skips the `HIT` reads, reads each file and manifest variant once, and expects `MISS` for every one. Run it only on a version the first run has already filled.

```bash
scripts/check-edge-cache.sh --after-purge \
  /api/datasets/spec_<id>/cv_<hex>/files/<digest> \
  '/api/datasets/spec_<id>/cv_<hex>/file?format=csv'
```

`scripts/check-edge-cache.test.sh` tests the script against a stub `curl`.

## Counting dataset reads

The website's request log misses every read that Cloudflare answers from its cache, which is most of what the cache rule exists to serve. `scripts/edge-usage.sh <start_date> <end_date>` estimates them at the edge. It queries the GraphQL Analytics API's `httpRequestsAdaptiveGroups` for GET requests to the dataset paths under both prefixes, and prints a tab-separated table of UTC day, prefix, kind (`file`, `manifest`, or `selector`), cache status, requests, bytes (`edgeResponseBytes`) and the `sampled` interval (`avg { sampleInterval }`; 1 means unsampled, 10 means one request in ten was sampled, and folded rows show the request-weighted mean). `EDGE_USAGE_BY_REFERER=1` adds the referring host as a column through the `clientRefererHost` dimension. Cloudflare's pages list `clientRequestPath` ([example](https://developers.cloudflare.com/analytics/graphql-api/tutorials/end-customer-analytics/)) and the 31-day minimum retention of adaptive datasets ([limits](https://developers.cloudflare.com/analytics/graphql-api/limits/)) but not each dataset's dimensions, so confirm `cacheStatus` and `clientRefererHost` by [introspection](https://developers.cloudflare.com/analytics/graphql-api/features/discovery/introspection/) with the analytics token before relying on the output; Cloudflare answers an unknown field with an error, which the script prints. These figures are sampled estimates; the lines in "Logpush" are the unsampled record of the same reads. `httpRequestsAdaptiveGroups` is an adaptive dataset, so Cloudflare samples it at a rate the caller cannot set ([sampling](https://developers.cloudflare.com/analytics/graphql-api/sampling/)) and scales the counts and bytes up from the sample. Use them for the cache hit share and the bytes served from the edge. They are a separate source from the analytics repo's dataset uses, which count dfo-apis delivery lines, and are never added to them. The query follows Cloudflare's [colo migration guide](https://developers.cloudflare.com/analytics/graphql-api/migration-guides/zone-analytics-colos/), which requests `sum { edgeResponseBytes }` and `avg { sampleInterval }` on this dataset. The script exits 1 when an answer reaches the 10,000-row limit, so query a shorter range.

The token is read-only: Analytics Read on the zone, in the macOS keychain service `dfo-cloudflare-edge-analytics`, or exported as `CLOUDFLARE_ANALYTICS_API_TOKEN`. `scripts/edge-usage.test.sh` tests the script against a stub `curl`.

## Apply order

Edge applies after `telemetry` once `edge_logpush_bucket` is set, since the Logpush job writes to telemetry's bucket; both are consumers in `apply.yml` and run side by side, so the bucket must exist before the edge change that sets the variable merges. Edge also applies after `foundation`, which grants the applier the load balancer, Cloud Armor, and Certificate Manager roles and lets it write this stack's state, and after `website`, whose Cloud Run service the endpoint group names. The stack enables `certificatemanager.googleapis.com` itself. The first apply can fail with `SERVICE_DISABLED` on the Certificate Manager resources while the API propagates. Recover with a `workflow_dispatch` of `apply.yml` with `stack=edge`. The same dispatch recovers an apply where the `apis` producer tier failed and skipped edge.

## Made by hand first

- A local backend init, `just ENV=dfo-prod STACK=edge bootstrap`, once `foundation` has applied.
- The Cloudflare API token, zone-scoped to developmentfinance.org. CI reads it from the `CLOUDFLARE_API_TOKEN` secret in the `production` (edit) and `plan` (read) environments. Locally, export it from the macOS keychain service `dfo-cloudflare-edge-apply` or `dfo-cloudflare-edge-plan` as `CLOUDFLARE_API_TOKEN`. The provider reads only that variable. The apply token needs Cache Rules Edit permission on the zone for the cache ruleset, and the plan token needs Cache Rules Read. Once `edge_logpush_bucket` is set, both need Logs Write on the zone: Cloudflare requires it for every Logpush API call, reads included ([permissions](https://developers.cloudflare.com/logs/logpush/permissions/)), so the plan token cannot refresh the job or the ownership challenge without it. Cloudflare's [custom fields page](https://developers.cloudflare.com/logs/logpush/logpush-job/custom-fields/) names no permission for the `http_log_custom_fields` ruleset, so if the apply answers 403 on `cloudflare_ruleset.log_custom_fields`, the token needs Logs Write there too.
- The purge token, zone-scoped to developmentfinance.org with the Cache Purge permission and nothing else, for the purge in "Revoking a dataset version". Terraform does not read it. It lives in the macOS keychain service `dfo-cloudflare-edge-purge` of whoever writes revocations. The stack's own tokens are zone-scoped and cannot create tokens, so it is made in the Cloudflare dashboard.
- The analytics token, zone-scoped to developmentfinance.org with Analytics Read and nothing else, for `scripts/edge-usage.sh`. Terraform does not read it. It lives in the macOS keychain service `dfo-cloudflare-edge-analytics`.
