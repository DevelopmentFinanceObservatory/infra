# edge-logs (prod)

The Cloudflare Logpush job that records every dataset read the edge handles, in prod only. The `.tf` files are symlinks to `infra/stacks/edge-logs`. This directory holds prod's backend, tfvars, and lock file.

The stack holds the `dataset-reads` job, the ownership challenge it needs, and the zone's `http_log_custom_fields` ruleset. Each exists only while `edge_logpush_bucket` is set. The `edge_logpush_job_id` output is the job's id, or null while the bucket is unset. The edge stack's cache rule refuses to exist until this job is enabled and has delivered (`infra/dfo-prod/edge/README.md`, "Cloudflare").

## Tokens

Cloudflare requires Logs Write on the zone for every Logpush API call, reads included ([permissions](https://developers.cloudflare.com/logs/logpush/permissions/)), and the provider's Logpush data sources accept only Logs Write too ([`cloudflare_logpush_job`](https://registry.terraform.io/providers/cloudflare/cloudflare/5.27.0/docs/data-sources/logpush_job)). So this stack plans and applies only with the `production` environment's `CLOUDFLARE_API_TOKEN`, which needs Logs Write on the zone. `plan-prod.yml` leaves it out of every pull-request plan, with a notice, so the `plan` environment's token stays read-only and no reviewer sees an edge-logs plan before merge. A release therefore runs it in two jobs of `apply-stack.yml`, each approved by the `release` reviewers on its own. `plan for review` plans on main and runs the destroy guard, and its log is the plan. Read it, then approve `apply`, which plans again and applies only when its changes hash to the same value as the reviewed plan's (`scripts/plan-changes-sha256.sh`). When anything changed in between, the apply job stops, and a rerun of the workflow plans again for review. Locally, export the apply token from the macOS keychain service `dfo-cloudflare-edge-apply` as `CLOUDFLARE_API_TOKEN`. Cloudflare's [custom fields page](https://developers.cloudflare.com/logs/logpush/logpush-job/custom-fields/) names no permission for the `http_log_custom_fields` ruleset, so if the apply answers 403 on `cloudflare_ruleset.log_custom_fields`, the token needs Logs Write there too.

`plan-prod.yml` runs from main, so the change that adds `APPLY_ONLY_STACKS` to it reaches main in a release of its own, before the release that adds this directory. Otherwise main's copy tries to plan this stack with the `plan` token.

The first apply creates the stack's state. The applier writes it through its project-wide `roles/storage.admin`, and the planner's state grant in `infra/stacks/foundation/main.tf` leaves this prefix out.

## Logpush

Cloudflare Logpush writes one line for every GET the edge handles on a path starting `/api/datasets/` or `/api/v1/datasets/`, from any host, cache hits included, with no sampling (`sample_rate` 1). A read Cloudflare answers from its cache never reaches the website, so these lines are the only record of it. The job is `cloudflare_logpush_job.dataset_reads` in `infra/stacks/edge-logs/cloudflare_logpush.tf`, on the zone's [`http_requests` dataset](https://developers.cloudflare.com/logs/logpush/logpush-job/datasets/zone/http_requests/).

It writes gzipped NDJSON batches named `<start>_<end>_<hash>.log.gz` to `gs://dfo-prod-edge-logs-prod-fin-observatory/http_requests/<YYYYMMDD>/`, a bucket the telemetry stack owns (`infra/stacks/telemetry/edge_logs.tf`). The bucket is in the EU multi-region with uniform access and public access prevention enforced. Cloudflare's `logpush@cloudflare-data.iam.gserviceaccount.com` holds `roles/storage.objectAdmin` on it, the role the [GCS destination page](https://developers.cloudflare.com/logs/logpush/logpush-job/enable-destinations/google-cloud-storage/) asks for. The lines carry raw client IPs, so a lifecycle rule deletes each batch three days after it is written, which leaves time to repair a fault in the load into BigQuery before a batch expires, and soft delete is off. GCS acts on a lifecycle rule [asynchronously](https://cloud.google.com/storage/docs/lifecycle#behavior), so a batch can last up to about four days. The applier and the project owners can read the batches. The planner holds no object grant on the bucket.

Each line has these fields, in this order, with timestamps in RFC 3339 ([output options](https://developers.cloudflare.com/logs/logpush/logpush-job/log-output-options/)). `RequestHeaders` holds the two headers the custom fields rule names, as the request sent them ([custom fields](https://developers.cloudflare.com/logs/logpush/logpush-job/custom-fields/)). `OriginResponseStatus` is 0 when the edge answered without the origin.

```json
{"EdgeStartTimestamp":"2026-11-19T11:30:01Z","RayID":"8e3f2a1b4c5d6e7f","ClientRequestMethod":"GET","ClientRequestHost":"developmentfinance.org","ClientRequestPath":"/api/datasets/spec_<id>/cv_<hex>/files/<digest>","ClientRequestReferer":"https://developmentfinance.org/","ClientRequestUserAgent":"Mozilla/5.0 ...","ClientIP":"192.0.2.1","ClientCountry":"gb","CacheCacheStatus":"hit","EdgeResponseStatus":200,"EdgeResponseBytes":48213,"OriginResponseStatus":0,"RequestHeaders":{"origin":"https://developmentfinance.org","x-dfo-client":"<client>"}}
```

`ClientRequestPath` has no query string. The `/file` selector is the only dataset read with one, and it is never cached, so the website's request log carries its format.

The filter is a [Logpush filter](https://developers.cloudflare.com/logs/logpush/logpush-job/filters/): `ClientRequestMethod` `eq` `GET`, and `ClientRequestPath` `startsWith` either prefix. Its operators are case-sensitive, so the edge stack's cache rule repeats the same prefix test, and nothing the cache serves falls outside the filter. `dataset_path_prefixes` in `infra/stacks/edge-logs/cloudflare_logpush.tf` and in `infra/stacks/edge/cloudflare_rules.tf` must list the same prefixes.

Cost: Logpush to an external destination such as GCS includes 25 GB a month per Cloudflare account, then $0.10 per GB, counted on uncompressed delivered bytes ([pricing](https://developers.cloudflare.com/logs/logpush/pricing/)). The allowance covers every zone in ONE's account, so any other Logpush job there draws on it too.

Health: Logpush cannot backfill. A period when the job is disabled or failing is lost for good ([Logpush](https://developers.cloudflare.com/logs/logpush/)). Cloudflare's only Logpush notification, Failing Logpush Job Disabled (`failing_logpush_job_disabled_alert` in `cloudflare_notification_policy`), is listed for Enterprise plans ([available notifications](https://developers.cloudflare.com/notifications/notification-available/)) and is account-scoped, which the zone-scoped token cannot write, so the stack does not create it. The zone's Logpush page has a Health tab with 30 days of upload results ([health dashboards](https://developers.cloudflare.com/logs/logpush/logpush-health/)). Run `scripts/check-edge-logpush.sh` after every edge-logs apply and whenever the counts look low.

### Checking the feed

`scripts/check-edge-logpush.sh <bucket>` reads with `gcloud storage` only. It reads the batches that end in the last hour, counts the lines on the two dataset prefixes whose `EdgeStartTimestamp` falls in that hour, and prints them by `CacheCacheStatus`. It exits 1 when there are none, when a line lacks `CacheCacheStatus` or `ClientIP`, or when a day directory older than four days holds anything but the ownership challenge file, and 2 on a usage error. It needs `storage.objects.list` and `get` on the bucket, which the applier and the project owners hold. An idle hour has no lines, so send one read first:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://developmentfinance.org/api/v1/datasets/spec_<id>/cv_<hex>
scripts/check-edge-logpush.sh dfo-prod-edge-logs-prod-fin-observatory
```

`scripts/check-edge-logpush.test.sh` tests the script against a stub `gcloud`.

## Before the first apply

A zone holds one entrypoint ruleset per phase, so creating the custom fields ruleset fails when the zone already has one for `http_log_custom_fields`. List the zone's rulesets for that phase with a read-only call:

```bash
curl -sS "https://api.cloudflare.com/client/v4/zones/e837f8819d4b16dce14e17cbe6ba3716/rulesets" \
  -H "Authorization: Bearer $(security find-generic-password -s dfo-cloudflare-edge-plan -w)" |
  jq '.result[] | select(.phase == "http_log_custom_fields") | {id, name, kind, phase}'
```

An empty answer means the create works. When the call lists an entrypoint, add an `import` block for `cloudflare_ruleset.log_custom_fields[0]` with the id `zones/e837f8819d4b16dce14e17cbe6ba3716/<ruleset id>` to `cloudflare_logpush.tf`, and make the resource's `name` and `kind` match the listed ones, since a change would replace the ruleset. Remove the block once state holds the ruleset.

## Apply order

The cache rule in the edge stack cannot exist without this job, and the job writes to the telemetry stack's bucket. Each step below is its own merge to main, since `apply.yml` runs telemetry, edge-logs and edge side by side as consumers.

1. Apply the telemetry stack, which creates the bucket and the Logpush grant. Its `edge_logs_bucket` output is the bucket name.
2. Run the check in "Before the first apply". Set `edge_logpush_bucket` in `infra/dfo-prod/edge-logs/env.auto.tfvars` to the bucket name and apply this stack. The apply creates the custom fields rule, asks Cloudflare for an ownership challenge, which Cloudflare writes to the bucket as `ownership-challenge-<random>.txt`, reads the token from that file, and creates the job with it ([ownership challenge](https://developers.cloudflare.com/logs/logpush/logpush-job/logpush-ownership-challenge/)). Leave the challenge file in place: every plan of this stack reads it, and the bucket's delete rule matches only `.log.gz`.
3. Send a read and run `scripts/check-edge-logpush.sh` until it passes, as "Checking the feed" shows.
4. Set `edge_cache_enabled = true` in `infra/dfo-prod/edge/env.auto.tfvars` and apply the edge stack. Its precondition reads the job and refuses the cache unless the job is enabled and reports a `last_complete`. Then run `scripts/check-edge-cache.sh` as `infra/dfo-prod/edge/README.md`, "Checking the cache after an apply", describes, and `scripts/check-edge-logpush.sh` again, which should now count `hit` lines. The cache is live only when `infra/dfo-prod/edge/README.md`, "Confirming that a miss and a hit both reach BigQuery", passes; raw batches expire after three days, so run it inside that window.

To turn the cache off, set `edge_cache_enabled` to false in the edge stack and apply. Remove the job only after that apply. This stack does not read the cache rule, so unsetting `edge_logpush_bucket` while the cache is on deletes the job and leaves cached reads unlogged until the next edge plan fails its precondition.
