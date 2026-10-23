# telemetry (prod)

Prod's telemetry plumbing in BigQuery, which the team dashboard reads through the `dfo_reporting` dataset. The stack routes Cloud Run logs into a Log Analytics bucket, aggregates them daily into `logs_daily`, holds the dataset Search Console exports into, and grants readers access to `dfo_reporting`. The `.tf` files and the `sql` directory are symlinks to `infra/stacks/telemetry`. This directory holds prod's backend, tfvars, and lock file. The stack exists in prod only.

Every dataset is in the EU multi-region. Every dataset-level grant is a `google_bigquery_dataset_access`, and no dataset declares `access` blocks. Authoritative blocks, or `google_bigquery_dataset_iam_*` resources, would remove the other entries on the next apply, including the authorised-view entries the reporting views need on their sources.

## Logs

The sink `dfo-prod-telemetry` copies every `cloud_run_revision` and `cloud_run_job` entry from the `run.googleapis.com/requests`, `stdout` and `stderr` logs into the bucket `dfo-prod-telemetry` in `eu`, which keeps them for `log_retention_days` (30). The `_Default` bucket still receives the same entries. The filter names resource types and log ids, so a new or renamed service is routed with no change here. It leaves out the website's usage-event lines (`jsonPayload.message="event"` on `dfo-prod-website`'s stdout). They repeat the Postgres `event` table, which is the events source the website export copies, and their props carry the first 500 characters of each search query.

The bucket's linked dataset `dfo_logs` exposes the entries to BigQuery as the view `dfo_logs._AllLogs`. The entries hold request IPs and user agents. BigQuery roles decide who can read them. The `dfo-prod-logs-daily` service account reads `dfo_logs` through its dataset grant. Any principal with a project-level BigQuery data role reads it too. Today those are the applier (`roles/bigquery.dataOwner`), `dfo-prod-dc-ing-pst-sa` (`roles/bigquery.dataEditor`), and the project owners. If the linked dataset carries BigQuery's default `projectWriters` and `projectReaders` entries, as datasets Terraform creates here do, the project's editors and viewers read it as well. Those are the default compute service account and the Google APIs service agent (`roles/editor`) and `dfo-infra-planner` (`roles/viewer`).

A sink routes only entries written after it exists, so `dfo_logs` starts empty and holds nothing from before the first apply.

## logs_daily

The scheduled query `dfo-prod-logs-daily` runs `sql/logs_daily.sql` at 02:00 UTC every day as `dfo-prod-logs-daily`. It creates four tables on its first run and writes them in one transaction:

- `requests_daily`: requests per day and service, with 4xx and 5xx counts and approximate p50, p95 and p99 latency in milliseconds.
- `routes_daily`: the same per day, service, method and route.
- `errors_daily`: stdout and stderr entries at `WARNING` or above per day, resource type, service or job, the structured `logger` field, and severity. Request logs are excluded, and so is every message.
- `deploys`: each revision that served a request, with the time of its first request and `before_source`. A revision that never passed its startup probe served nothing and has no row.

The oldest day in `dfo_logs` is partial, because the sink started or retention cut entries part way through it, so the oldest whole day is the one after. The first three tables reload the days from `requests_daily`'s latest loaded day minus one through today, and from the oldest whole day when `requests_daily` is empty. The start never falls before the oldest whole day, so a run deletes only days it reloads in full. `errors_daily` shares the start, so a stretch with no warnings cannot widen its window. A missed run heals on the next one as long as the gap is shorter than the bucket's retention. A longer gap loses the days that aged out of the bucket and keeps every day already loaded.

`deploys` adds each revision it has not seen, timed over the whole of `dfo_logs`, and never changes a row. `before_source` is true, as of the run that records the revision, when no other revision of the same service served a request earlier in `dfo_logs`. A revision with an earlier sibling was deployed after the source began. One without was serving when the source began, or is the first after a service-wide silence longer than retention, or the first revision of a new service. Its `first_request` is not a known deploy, so deploy markers read only rows where `before_source` is false. Recording it keeps later runs from adding it again once retention trims its early requests, which would time a sparse revision at a request weeks after its deploy. The rule drops the marker of a new service's first deploy. It has one known false marker. An old revision that held 0% of traffic or served only a tag, and later takes traffic, is recorded as a deploy on that later day.

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

## Web history before the exports

Neither the GA4 BigQuery link nor Search Console's bulk export backfills, and developmentfinance.org has been live since 2026-10-05. Two one-off loaders read the products' APIs for the days before each export's first day and write them to the dataset `web_history`:

- `scripts/load-ga4-history.sh` reads the GA4 Data API into `ga4_pages_daily`, with active users, sessions and page views per day and page path, and `ga4_daily`, with the same per day, since users do not sum across pages.
- `scripts/load-search-console-history.sh` reads the Search Analytics API into `search_console_pages_daily`, with clicks, impressions and `sum_position` per day and page URL, and `search_console_daily`, with the same for the whole property. It reads final web-search data and requests no query dimension.

`sum_position` is on the bulk export's scale, with the top position as 0. It is the API's average position minus 1, times impressions. History and export rows therefore union without adjustment, and `sum_position / impressions + 1` is the average position as Search Console shows it.

GA4's `pagePath` holds no query string, so the GA4 loader stores it as returned. Users and sessions do not sum across pages, so a day with two rows for one path stops the run. The Search Console loader strips the query string and fragment from each URL and sums the rows that then match, since clicks, impressions and `sum_position` add up. The export's `url` keeps query strings, so a view must strip them the same way before the union. Each loader's first run creates its two tables, partitioned by `date`, with `CREATE TABLE IF NOT EXISTS` statements that run before the transaction. In one transaction, a run then deletes every day in its range from both its tables and inserts the rows it read. A table with no rows in the range gets only the delete, so a rerun is safe and clears stale rows. The run prints the rows it loaded per day. GA4 days are in the property's reporting time zone and Search Console days in Pacific Time, as in their exports. The reporting views union these tables with the exports, taking history rows only for days before each export's first day.

The loaders run as the service account in the `web_history_service_account` output, `dfo-prod-web-history`, which has `WRITER` on `web_history` and `roles/bigquery.jobUser` on the project. Before the first run, once:

- In GA4, under Admin, Property access management, add the service account's address with the Viewer role.
- In Search Console, under Settings, Users and permissions, a property owner adds the address as a Restricted user.
- Give the person running the loaders `roles/iam.serviceAccountTokenCreator` on the service account. Terraform sets no IAM policy on the account, so the binding stays until `remove-iam-policy-binding` with the same flags removes it.

```sh
gcloud iam service-accounts add-iam-policy-binding \
  "$(terraform -chdir=infra/dfo-prod/telemetry output -raw web_history_service_account)" \
  --project=prod-fin-observatory --member=user:<address> --role=roles/iam.serviceAccountTokenCreator
```

Then, from the repository root, load from launch to the day before each export's first day. Both APIs finish a day's figures about 2 to 3 days late, and a run replaces every day in its range, so a loader refuses an end date later than 4 days before today in UTC. The fourth day covers Search Console's Pacific Time days. Run it once the day before the export's first day is that old. `<site_url>` is `sc-domain:developmentfinance.org` for a Domain property, or the URL prefix with its trailing slash.

```sh
scripts/load-ga4-history.sh <ga4_property_id> 2026-10-05 <day before the GA4 export's first day>
scripts/load-search-console-history.sh <site_url> 2026-10-05 <day before the bulk export's first day>
```

`scripts/web-history.test.sh` runs both loaders against stub `curl`, `gcloud` and `terraform` commands and the hand-written API responses in `scripts/testdata/web-history`. Run it by hand after changing either loader or `scripts/web-history-lib.sh`.

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
