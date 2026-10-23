# telemetry (prod)

Prod's telemetry plumbing in BigQuery, which the team dashboard reads through the `dfo_reporting` dataset. The stack routes Cloud Run logs into a Log Analytics bucket, holds a one-off copy of the Cloud Run logs from before that route started, aggregates both daily into `logs_daily`, holds the dataset Search Console exports into, and grants readers access to `dfo_reporting`. The `.tf` files and the `sql` directory are symlinks to `infra/stacks/telemetry`. This directory holds prod's backend, tfvars, and lock file. The stack exists in prod only.

Every dataset is in the EU multi-region. Every dataset-level grant is a `google_bigquery_dataset_access`, and no dataset declares `access` blocks. Authoritative blocks, or `google_bigquery_dataset_iam_*` resources, would remove the other entries on the next apply, including the authorised-view entries the reporting views need on their sources.

## Logs

The sink `dfo-prod-telemetry` copies every `cloud_run_revision` and `cloud_run_job` entry from the `run.googleapis.com/requests`, `stdout` and `stderr` logs into the bucket `dfo-prod-telemetry` in `eu`, which keeps them for `log_retention_days` (30). The `_Default` bucket still receives the same entries. The filter names resource types and log ids, so a new or renamed service is routed with no change here. It leaves out the website's usage-event lines (`jsonPayload.message="event"` on `dfo-prod-website`'s stdout). They repeat the Postgres `event` table, which is the events source the website export copies, and their props carry the first 500 characters of each search query.

The bucket's linked dataset `dfo_logs` exposes the entries to BigQuery as the view `dfo_logs._AllLogs`. The entries hold request IPs and user agents. BigQuery roles decide who can read them. The `dfo-prod-logs-daily` service account reads `dfo_logs` through its dataset grant. Any principal with a project-level BigQuery data role reads it too. Today those are the applier (`roles/bigquery.dataOwner`), `dfo-prod-dc-ing-pst-sa` (`roles/bigquery.dataEditor`), and the project owners. If the linked dataset carries BigQuery's default `projectWriters` and `projectReaders` entries, as datasets Terraform creates here do, the project's editors and viewers read it as well. Those are the default compute service account and the Google APIs service agent (`roles/editor`) and `dfo-infra-planner` (`roles/viewer`).

A sink routes only entries written after it exists, so `dfo_logs` starts empty and holds nothing from before the first apply. Its first entry is at 2026-10-23 18:48:34.611764 UTC, but it routed every entry only from about 18:50, and three entries timestamped between 18:49 and 18:50 reached only `_Default`. `logs_daily` therefore reads `dfo_logs` from a cut-off of 2026-10-23 19:00:00 UTC, and the backfill below before it.

## Backfill

`logs_daily.backfill_entries` holds the Cloud Run entries from `_Default` with timestamps before the cut-off, back to the start of `_Default`'s 30-day retention, about 2026-09-23. Terraform declares its schema, which is the part of `dfo_logs._AllLogs` that `sql/logs_daily.sql` reads: `timestamp`, `log_id`, `severity`, `resource`, `http_request` with method, URL, status and latency, and `json_payload`. It keeps only the entries the sink's filter routes, so the website's usage-event lines are absent, and `json_payload` holds only the `logger` field, so the table holds no message text. The staging table the loader fills holds only the `logger` and `message` fields of each payload, so the website usage events' props, which carry search queries, are not loaded into BigQuery. It holds request URLs with their query strings, and no IP or user agent. Every principal that reads `logs_daily` reads it.

The view `logs_daily.entries` (`sql/entries.sql`) is `dfo_logs._AllLogs` from the cut-off on and `backfill_entries` before it, in those columns, and `logs_daily.sql` reads it as its source. The cut-off is the constant `logs_backfill_cutoff` in `logs_daily.tf`, so no entry appears twice, none is missing, and the view stays correct after retention moves `dfo_logs`'s oldest entry forward. `dfo-prod-logs-daily` reads the view through its `WRITER` grant on `logs_daily` and its `READER` grant on `dfo_logs`.

The copy is two hand-run `gcloud logging copy` operations from `_Default`, both filtered to `(resource.type="cloud_run_revision" OR resource.type="cloud_run_job")`, one for timestamps before 2026-10-23T18:48:34Z and one for 2026-10-23T18:48:34Z up to the cut-off, into the bucket `gs://prod-fin-observatory-logs-backfill` (EU, objects deleted after 14 days, made by hand). The copies write LogEntry JSON, one entry per line. `scripts/load-logs-backfill.sh` loads those files into `backfill_entries`:

```sh
scripts/load-logs-backfill.sh --ignore-operation=CAESEzkwNzkxOTQ2NTY4NDM4MzI2NDg \
  prod-fin-observatory dfo-prod gs://prod-fin-observatory-logs-backfill
```

It refuses to run while the bucket holds no `.json` object, while no copy into the bucket is on record, or while any copy into it has not succeeded, since a running, failed or cancelled copy leaves days part-written. Entries copied twice load once. The first copy attempt, operation `CAESEzkwNzkxOTQ2NTY4NDM4MzI2NDg`, was cancelled, and the copy after it repeats its range, so the load passes `--ignore-operation=CAESEzkwNzkxOTQ2NTY4NDM4MzI2NDg`. `--skip-copy-check` skips the check once the operation records have expired. It loads the files into a staging table that expires after a day and that it deletes on exit, replaces every row of `backfill_entries` with `sql/backfill_entries.sql`'s output in one `MERGE`, and prints the entries kept per day. A rerun replaces the previous load. Run it before the bucket's objects expire. `infra/stacks/telemetry/tests/backfill_entries.test.sh` runs `sql/backfill_entries.sql` over literal entries and fails on any row that differs from the one it pins. Run it by hand after changing the query.

### Rebuilding logs_daily from the backfill

`requests_daily`, `routes_daily` and `errors_daily` reload only from their latest day minus one, and `deploys` never changes a row, so the tables written before the load hold no backfill days and time each revision against `dfo_logs` alone. After the first load, and after any reload, empty the four tables and run the query once. With `requests_daily` empty it loads from the backfill's oldest whole day, and `deploys` computes `before_source` against the longer source.

```sh
bq query --project_id=prod-fin-observatory --location=EU --use_legacy_sql=false \
  'TRUNCATE TABLE `prod-fin-observatory.logs_daily.requests_daily`;
   TRUNCATE TABLE `prod-fin-observatory.logs_daily.routes_daily`;
   TRUNCATE TABLE `prod-fin-observatory.logs_daily.errors_daily`;
   TRUNCATE TABLE `prod-fin-observatory.logs_daily.deploys`;'
config="$(bq ls --transfer_config --transfer_location=EU --project_id=prod-fin-observatory --format=json |
  jq -r '.[] | select(.displayName == "dfo-prod-logs-daily") | .name')"
bq mk --transfer_run --run_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$config"
```

The run's progress shows on the BigQuery console's Scheduled queries page. The dashboard reads empty tables between the truncate and the run's end.

## logs_daily

The scheduled query `dfo-prod-logs-daily` runs `sql/logs_daily.sql` at 02:00 UTC every day as `dfo-prod-logs-daily`. It reads `logs_daily.entries`, which is `dfo_logs` from the cut-off on and `backfill_entries` before it. It creates four tables on its first run and writes them in one transaction:

- `requests_daily`: requests per day and service, with 4xx and 5xx counts and approximate p50, p95 and p99 latency in milliseconds.
- `routes_daily`: the same per day, service, method and route.
- `errors_daily`: stdout and stderr entries at `WARNING` or above per day, resource type, service or job, the structured `logger` field, and severity. Request logs are excluded, and so is every message.
- `deploys`: each revision that served a request, with the time of its first request and `before_source`. A revision that never passed its startup probe served nothing and has no row.

The oldest day in `logs_daily.entries` is partial, because the copy or retention cut entries part way through it, so the oldest whole day is the one after. The first three tables reload the days from `requests_daily`'s latest loaded day minus one through today, and from the oldest whole day when `requests_daily` is empty. The start never falls before a floor, so a run deletes only days it reloads in full. While `dfo_logs` reaches back to the cut-off, the view has no gap and the floor is the view's oldest whole day. From about 2026-11-22, retention moves `dfo_logs`'s oldest entry past the cut-off, the view has a gap between the backfill and that entry, and the floor becomes `dfo_logs`'s oldest whole day. `logs_daily.sql` reads `dfo_logs` directly for that test. An empty `dfo_logs` with days already loaded gives no start, so the run deletes and loads nothing. `errors_daily` shares the start, so a stretch with no warnings cannot widen its window. The day of the cut-off is whole, since the backfill holds its entries before the cut-off and `dfo_logs` the rest. A missed run heals on the next one as long as the gap is shorter than the bucket's retention. A longer gap loses the days that aged out of the bucket and keeps every day already loaded.

`infra/stacks/telemetry/tests/load_from.test.sh` runs the query's start-day statements over literal sources, through both floors and an empty source, and fails on any start that differs from the one it pins. Run it by hand after changing those statements.

`deploys` adds each revision it has not seen, timed over the whole of `logs_daily.entries`, and never changes a row. `before_source` is true, as of the run that records the revision, when no other revision of the same service served a request earlier in `logs_daily.entries`. A revision with an earlier sibling was deployed after the source began. One without was serving when the source began, or is the first after a service-wide silence longer than retention, or the first revision of a new service. Its `first_request` is not a known deploy, so deploy markers read only rows where `before_source` is false. Recording it keeps later runs from adding it again once retention trims its early requests, which would time a sparse revision at a request weeks after its deploy. The rule drops the marker of a new service's first deploy. It has one known false marker. An old revision that held 0% of traffic or served only a tag, and later takes traffic, is recorded as a deploy on that later day.

Days are UTC.

### Routes

`logs_daily.normalise_route(url)` turns a request URL into a route. It drops the scheme, host, query string, fragment and trailing slashes, collapses everything under `/_next/static/` to `/_next/static/:asset`, and replaces a path segment with `:id` when it starts with a digit, holds an upper-case letter, is a UUID, or holds a digit with no hyphen or dot. API versions such as `v1` stay. The body lives in `sql/normalise_route.sql`.

A share id made only of lower-case letters keeps its value, since nothing in its shape tells it from a word. With 8 characters drawn from 62, about one share id in 1,000 has that shape.

`infra/stacks/telemetry/tests/normalise_route.test.sh` runs the function over `tests/route_sample.tsv`, 323 URL shapes recorded from prod request logs plus hand-written cases, and fails on any route that differs from the one pinned beside it. The query reads only literals and scans no bytes. Run it by hand after changing the function, and add the new shape to the fixture.

## Alerts

Each address in the principals secret's `alerts` object gets its own Cloud Monitoring email channel, named by its label, and every alert in this stack notifies all of them. Five policies watch the data pipeline the dashboard reads:

- `logs_daily scheduled query failed` fires when a run logs an error against the config, or when the Data Transfer Service counts a run as `FAILED`. A run that keeps failing for longer than the bucket's retention loses those days for good.
- `dfo-prod-website-export Job execution failed` fires when an execution of the website's hourly event export Job fails.
- `dfo-prod-langfuse-export Job execution failed` fires when an execution of the ai stack's hourly Langfuse export Job fails. Langfuse Cloud keeps observations for a limited time, so a long run of failures loses data.
- `dfo-prod-website-export Job not succeeding` and `dfo-prod-langfuse-export Job not succeeding` fire when a Job has no succeeded execution for three hours. They catch what the failure policies cannot see: a paused or failing Scheduler trigger, a renamed or deleted Job, or every run failing. Each is its own policy with a seven-day auto-close, since a shorter timer would close the incident while no execution succeeds.

The four Job policies read Cloud Run's `run.googleapis.com/job/completed_execution_count`, with `result="failed"` or `result="succeeded"`, filtered by job name. The Jobs belong to the website and ai stacks, and this stack names them by their fixed names. A Job not yet created has no series, so its policies stay quiet, and the absence policy starts watching after the Job's first succeeded execution, since Cloud Monitoring needs one measurement before a series can go absent.

## Search Console

The dataset `searchconsole` takes Search Console's bulk data export. `search-console-data-export@system.gserviceaccount.com` gets `WRITER` on it and `roles/bigquery.jobUser` on the project. The export has no backfill, so the data starts from the day it is turned on. Search Console's setup docs ask for project-level `roles/bigquery.dataEditor` for that account. If the bulk-export setup refuses the dataset-level grant, the documented fallback is project-level `roles/bigquery.dataEditor` for `search-console-data-export@system.gserviceaccount.com`.

## Readers

The principals secret's `readers` object lists the readers of `dfo_reporting` as IAM member strings. Each gets `READER` on `dfo_reporting`, and `roles/bigquery.jobUser` and `roles/mcp.toolUser` on the project, and no access to `logs_daily`, `dfo_logs`, `searchconsole`, or any other source dataset.

## Principals secret

The readers and alert recipients live in the Secret Manager secret `dfo-prod-telemetry-principals`. Prod plans run in public GitHub Actions logs, and every value from the secret prints there as `(sensitive value)`. `readers` holds IAM members and `alerts` at least one bare address:

```json
{
  "readers": { "team": "group:readers@example.org" },
  "alerts": { "team": "alerts@example.org" }
}
```

To create the secret or change its members, write the JSON to a file outside the repository and run

```sh
scripts/bootstrap-principals.sh prod-fin-observatory dfo-prod-telemetry-principals principals.json
```

[`infra/modules/principals-secret/README.md`](../../modules/principals-secret/README.md) states the rules the secret must meet, what the script does, and the relabel order.

## Apply order

Telemetry applies after `foundation`, which lets the applier write this stack's state and grants it the custom role `dfoInfraApplierTransferConfigs` for the scheduled query.

## Made by hand first

- A local backend init, `just ENV=dfo-prod STACK=telemetry bootstrap`, once `foundation` has applied.
- The principals secret `dfo-prod-telemetry-principals`, written with `scripts/bootstrap-principals.sh` as "Principals secret" describes. Plan fails while it does not exist.
- The Google groups the secret names. The reader grants fail while a reader group does not exist, and an alert group must accept mail from outside its domain, since Cloud Monitoring sends from a google.com address.
- The BigQuery Data Transfer Service agent, `service-<project number>@gcp-sa-bigquerydatatransfer.iam.gserviceaccount.com`. The grant that lets it run `dfo-prod-logs-daily` fails while the agent does not exist, and the applier cannot create it. A project owner creates it once with `gcloud beta services identity create --service=bigquerydatatransfer.googleapis.com --project=prod-fin-observatory`.

## After the first apply

- In Search Console, under Settings, Bulk data export, a property owner of developmentfinance.org enters the project `prod-fin-observatory`, the dataset `searchconsole`, and the location EU. The first export arrives within 48 hours.
- The first run of `dfo-prod-logs-daily` follows at the next 02:00 UTC. To run it sooner, start a manual run from the BigQuery console's Scheduled queries page.
