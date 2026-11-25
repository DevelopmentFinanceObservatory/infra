# telemetry (prod)

Prod's telemetry plumbing in BigQuery, which the team dashboard reads through the `dfo_reporting` dataset. The stack routes Cloud Run logs into a Log Analytics bucket, keeps an archive of the Cloud Run logs from before that route started, holds the dataset Search Console exports into, holds `dfo_reporting` and grants readers access to it, and holds the datasets, accounts and scheduled Jobs of the analytics repository. The `.tf` files and the `sql` directory are symlinks to `infra/stacks/telemetry`. This directory holds prod's backend, tfvars, and lock file. The stack exists in prod only.

Every dataset is in the EU multi-region. Every dataset-level grant is a `google_bigquery_dataset_access`, and no dataset declares `access` blocks except `logs_daily_archive` ("Logs"). Authoritative blocks, or `google_bigquery_dataset_iam_*` resources, would remove the other entries on the next apply, including authorised-view entries such as the one `billing_dfo.costs` needs on `billing_export`.

## Logs

The sink `dfo-prod-telemetry` copies every `cloud_run_revision` and `cloud_run_job` entry from the `run.googleapis.com/requests`, `stdout` and `stderr` logs into the bucket `dfo-prod-telemetry` in `eu`, which keeps them for `log_retention_days` (365, set in `env.auto.tfvars`). The `_Default` bucket also receives the same entries. The filter names resource types and log ids, so a new or renamed service is routed with no change here. It leaves out the website's usage-event lines (`jsonPayload.message="event"` on `dfo-prod-website`'s stdout). They repeat the Postgres `event` table, which is the events source the website export copies, and their props carry the first 500 characters of each search query.

The bucket's linked dataset `dfo_logs` exposes the entries to BigQuery as the view `dfo_logs._AllLogs`. The entries hold request IPs and user agents. BigQuery roles decide who can read them. `dfo-prod-analytics-ci`, `dfo-prod-analytics-runner` and the analytics developers read `dfo_logs` through their dataset grants ("Analytics repo"). Any principal with a project-level BigQuery data role reads it too. Those are the applier (`roles/bigquery.dataOwner`), `dfo-prod-dc-ing-pst-sa` (`roles/bigquery.dataEditor`), and the project owners. If the linked dataset carries BigQuery's default `projectWriters` and `projectReaders` entries, as datasets Terraform creates here do, the project's editors and viewers read it as well. Those are the default compute service account and the Google APIs service agent (`roles/editor`) and `dfo-infra-planner` (`roles/viewer`).

A sink routes only entries written after it exists, and this one routes every entry only from about 18:50 UTC on 2026-10-23.

The dataset `logs_daily_archive` (`logs.tf`) is a copy of the retired `logs_daily` dataset's seven tables. Its `backfill_entries` holds raw Cloud Run log entries from before 2026-10-23, with caller IPs and user agents, so its one `access` block gives `OWNER` to the project owners and nothing else. The block is authoritative: an apply removes any grant added outside it. No `google_bigquery_dataset_access` names the dataset, and it is not an analytics source.

## Alerts

Each address in the principals secret's `alerts` object gets its own Cloud Monitoring email channel, named by its label, and every alert in this stack notifies all of them. Four policies watch the export Jobs whose datasets the analytics build reads:

- `dfo-prod-website-export Job execution failed` fires when an execution of the website's hourly event export Job fails.
- `dfo-prod-langfuse-export Job execution failed` fires when an execution of the ai stack's hourly Langfuse export Job fails. Langfuse Cloud keeps observations for a limited time, so a long run of failures loses data.
- `dfo-prod-website-export Job not succeeding` and `dfo-prod-langfuse-export Job not succeeding` fire when a Job has no succeeded execution in the last three hours of stored data. They catch what the failure policies cannot see: a paused or failing Scheduler trigger, a renamed or deleted Job, or every run failing. Each is its own policy with a seven-day auto-close, since a shorter timer would close the incident while no execution succeeds.

With `analytics_jobs_enabled` on, `analytics_jobs.tf` adds twenty-two more with every probe, topics pass and the observation specs Job switched on, and three once `analytics_dbt_schedule_enabled` is on too:

- `dfo-prod-analytics-edge Job not succeeding` fires when the edge extract has no succeeded execution for three hours, and `dfo-prod-analytics-dbt Job not succeeding` and `dfo-prod-analytics-freshness Job not succeeding` do the same for the dbt build and the freshness check once `analytics_dbt_schedule_enabled` gives them triggers. A single failed dbt or edge run raises nothing, since the next run retries it: the dbt build replaces the last three days, and the extract reads each object for three days after it lands. A failed freshness run alerts through its own failure policy below. Each has a seven-day auto-close.
- `dfo-prod-analytics-grade Job execution failed` fires when an execution of the daily grader fails, since its retry is a day away. `dfo-prod-analytics-ga4-user-ranges Job execution failed` does the same for the daily GA4 user ranges extract.
- `dfo-prod-analytics-ga4-user-ranges Job not succeeding` fires when the GA4 user ranges extract has no succeeded execution in the last 26 hours, a PromQL condition built as the grade one is. It exists with the Job's trigger, so it opens within minutes of the apply and closes after the Job's first success.
- `dfo-prod-analytics-grade Job not succeeding` fires when the grader has no succeeded execution in the last 26 hours, a PromQL condition that sums the succeeded executions over the window and also fires when the series is absent. It alerts within minutes of the flag going on and closes after the Job's first success.
- `dfo-prod-analytics-topics-variables Job execution failed`, `dfo-prod-analytics-topics-turns Job execution failed` and `dfo-prod-analytics-topics-specs Job execution failed` fire when an execution of a topics pass fails. The `turns` and `specs` retries are a day away and the `variables` retry a week.
- `dfo-prod-analytics-topics-variables Job not succeeding` fires when the weekly pass has no succeeded execution in 192 hours, evaluated hourly. `dfo-prod-analytics-topics-turns Job not succeeding` and `dfo-prod-analytics-topics-specs Job not succeeding` fire when a daily pass has none in 26 hours, evaluated every 300 s as the grade policy is. Each is a PromQL condition built as the probes' are, exists only once its entry in `analytics_probes_enabled` is true, and closes after the pass's next success.
- `dfo-prod-analytics-call-specs Job not succeeding` fires when the hourly observation specs extract has no succeeded execution for five hours. The Job skips 04:35, 05:35 and 06:35, so two successes can be four hours apart, and the fifth hour covers one failed run beside the gap. A single failed run raises nothing, since the next run retries it. It exists only once the `call-specs` entry in `analytics_probes_enabled` is true, and it reads the five hours before it, so a switch-on more than five hours after the canary opens an incident that closes at the first scheduled success.
- `dfo-prod-analytics-call-specs lost observation rows` fires when the Job logs a line with `event="observation_spec_lost"`, one for each observation row that failed its last attempt, with the fields `observation_id` and `last_status`. The run itself succeeds, so no Job policy sees it. The log-based metric `dfo-prod-analytics-call-specs-lost` counts those lines on the Job, and the policy exists whatever the switch says.
- `dfo-prod-analytics-edge lost rejected, unreadable or deleted objects` fires when the edge extract's `run summary:` line, its last stdout line, carries `rejected=`, `unreadable=` or `deleted=` above zero. The log-based metric `dfo-prod-analytics-edge-objects-lost` counts those lines with the filter `textPayload=~"^run summary: .* (rejected|unreadable|deleted)=[1-9]"` on the edge Job, as the analytics repository's README documents. Each such object's deliveries are lost: a rejected one was named in `EDGE_REJECT_OBJECTS`, an unreadable one could not be decompressed or exceeded 256 MiB, and a deleted one left the bucket between the listing and the read. The run itself succeeds, so no Job policy sees it.
- `dfo-prod-analytics-dbt reconciliation test warned` fires when the dbt build prints a `WARN` result line for `assert_reconcile_dfo_apis`, `assert_reconcile_mcp`, `assert_reconcile_studio`, `assert_backfill_deliveries_counts_are_frozen` or `assert_delivery_line_cutover_vars_match_the_data`, tests at severity warn: the first three compare a producer's feeds per day and the last two guard the delivery-line cutover. The build succeeds on a warning, so no Job policy sees it. The log-based metric `dfo-prod-analytics-reconcile-warned` counts those lines on the dbt Job with the filter `textPayload=~" WARN [0-9]+ (assert_reconcile_(dfo_apis|mcp|studio)|assert_backfill_deliveries_counts_are_frozen|assert_delivery_line_cutover_vars_match_the_data) "`. The Job runs hourly, so a standing warning logs again each run and the incident auto-closes after two quiet hours. The policy exists whatever the switches say.
- `dfo-prod-analytics-freshness Job execution failed` fires when an hourly `dbt source freshness` run fails, which means a source the dbt build reads is older than the error threshold the analytics repository's `dbt/models/sources.yml` sets for it.
- `dfo-prod-analytics-repos Job execution failed`, `dfo-prod-analytics-lighthouse Job execution failed`, `dfo-prod-analytics-replay Job execution failed` and `dfo-prod-analytics-citations Job execution failed` fire when an execution of a probe fails, since its retry is a week or a month away. A probe whose trigger stops firing fails no run, which the next policy catches.
- `dfo-prod-analytics-repos Job not succeeding`, `dfo-prod-analytics-lighthouse Job not succeeding` and `dfo-prod-analytics-replay Job not succeeding` fire when a weekly probe has no succeeded execution in 192 hours, and `dfo-prod-analytics-citations Job not succeeding` when the monthly probe has none in 840 hours. Each is a PromQL condition built as the grade one is, so it catches a paused trigger or a deleted Job without the freshness Job. It exists only once its probe is switched on in `analytics_probes_enabled`, after a canary execution has succeeded, and closes after the probe's next success. Cloud Monitoring lets a PromQL condition that looks back 8 to 16 days evaluate hourly at most, and one that looks back 32 to 93 days every 6 hours, so the three weekly alerts evaluate every 3600 seconds and the citation alert every 21600 seconds. Each has a seven-day auto-close.

The Job policies read Cloud Run's `run.googleapis.com/job/completed_execution_count`, with `result="failed"` or `result="succeeded"`, filtered by job name. The Jobs belong to the website and ai stacks, and this stack names them by their fixed names. The failure policies stay quiet for a Job not yet created, which has no series. The not-succeeding policies are PromQL conditions over stored data, evaluated every five minutes for the hourly Jobs, so they also fire for a Job that has never succeeded or does not exist. The analytics ones exist only once their Job's trigger does.

## Search Console

The dataset `searchconsole` takes Search Console's bulk data export. `search-console-data-export@system.gserviceaccount.com` gets `WRITER` on it and `roles/bigquery.jobUser` on the project. The export has no backfill, so the data starts from the day it is turned on. If the bulk-export setup refuses the dataset-level grant, give that account project-level `roles/bigquery.dataEditor`, as Search Console's setup docs ask.

## Web history before the exports

Neither the GA4 BigQuery link nor Search Console's bulk export backfills, and developmentfinance.org has been live since 2026-10-05. Two one-off loaders read the products' APIs for the days before each export's first day and write them to the dataset `web_history`:

- `scripts/load-ga4-history.sh` reads the GA4 Data API into `ga4_pages_daily`, with active users, sessions and page views per day and page path, and `ga4_daily`, with the same per day, since users do not sum across pages.
- `scripts/load-search-console-history.sh` reads the Search Analytics API into `search_console_pages_daily`, with clicks, impressions and `sum_position` per day and page URL, and `search_console_daily`, with the same for the whole property. It reads final web-search data and requests no query dimension.

`sum_position` is on the bulk export's scale, with the top position as 0. It is the API's average position minus 1, times impressions. History and export rows therefore union without adjustment, and `sum_position / impressions + 1` is the average position as Search Console shows it.

GA4's `pagePath` holds no query string, so the GA4 loader stores it as returned. Users and sessions do not sum across pages, so a day with two rows for one path stops the run. The Search Console loader strips the query string and fragment from each URL and sums the rows that then match, since clicks, impressions and `sum_position` add up. The export's `url` keeps query strings, so a view must strip them the same way before the union. Each loader's first run creates its two tables, partitioned by `date`, with `CREATE TABLE IF NOT EXISTS` statements that run before the transaction. In one transaction, a run then deletes every day in its range from both its tables and inserts the rows it read. A table with no rows in the range gets only the delete, so a rerun is safe and clears stale rows. The run prints the rows it loaded per day. GA4 days are in the property's reporting time zone and Search Console days in Pacific Time, as in their exports. The analytics repository's models union these tables with the exports, taking history rows only for days before each export's first day.

The loaders run as the service account in the `web_history_service_account` output, `dfo-prod-web-history`, which has `WRITER` on `web_history` and `roles/bigquery.jobUser` on the project. Before the first run, once:

- In GA4, under Admin, Property access management, add the service account's address with the Viewer role. Add `dfo-prod-analytics-ga4-ranges`, the account of the `dfo-prod-analytics-ga4-user-ranges` Job ("Analytics jobs"), with the Viewer role the same way.
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

`scripts/web-history.test.sh` runs these loaders, `scripts/load-cloudflare-history.sh`, `scripts/load-cloudflare-pages-history.sh` and `scripts/load-website-page-history.sh` against stub `curl`, `gcloud` and `terraform` commands and the hand-written API responses and rows in `scripts/testdata/web-history`. Run it by hand after changing a loader or `scripts/web-history-lib.sh`.

## Cloudflare page loads

Cloudflare, which serves developmentfinance.org on the Pro plan, keeps 30 days of request analytics. Its page loads not made by verified bots count every visitor's page loads, whatever their consent, and are the only such count for the days before 2026-10-24, when the website's request log gained the status and bot fields that `website_requests_daily` reads. `web_history.cloudflare_daily` holds them per UTC day for 2026-10-05 to 2026-10-23, from this GraphQL Analytics API query over the zone:

```graphql
httpRequestsAdaptiveGroups(limit: 1000, orderBy: [date_ASC], filter: {date_geq: $start, date_leq: $end, requestSource: "eyeball", edgeResponseContentTypeName: "html", clientRequestHTTPMethodName: "GET", edgeResponseStatus: 200, clientRequestHTTPHost_in: ["developmentfinance.org", "www.developmentfinance.org"]}) { dimensions { date verifiedBotCategory } count }
```

`page_loads` sums a day's groups with an empty `verifiedBotCategory`, and `verified_bot_page_loads` the rest. No Cloudflare token is kept for this, so the capture was run once by hand, and the 30-day retention means a day can be captured again only within 30 days of it. To rerun a range, write the query's figures as JSON lines, one per day with `date`, `page_loads` and `verified_bot_page_loads`, and from the repository root run:

```sh
scripts/load-cloudflare-history.sh <rows.jsonl> <start_date> <end_date>
```

The loader runs as the same service account as the history loaders above and needs only `roles/iam.serviceAccountTokenCreator` on it. It replaces every day from start to end in `cloudflare_daily`, creating the table on its first run, so a rerun of a range with the same file gives the same table, and a day the file leaves out has no row afterwards. It refuses a file with no rows, a row without a date and whole, non-negative counts, a date outside the range and a date on more than one row. Cloudflare's figures are final once the UTC day ends, so the end date may be as late as yesterday in UTC, in place of the 4-day rule of the GA4 and Search Console loaders. Today is refused, since its figures are still partial.

### Page loads per path

The prototypes app at developmentfinance.org/prototypes is a Cloudflare Worker, so its page loads never reach the website's request log. `web_history.cloudflare_pages_daily` holds them per UTC day and path for 2026-11-16 to 2026-11-17, from the same query with `clientRequestPath_like: "/prototypes%"` added to the filter and `clientRequestPath` to the dimensions:

```graphql
httpRequestsAdaptiveGroups(limit: 1000, orderBy: [date_ASC], filter: {date_geq: $start, date_leq: $end, requestSource: "eyeball", edgeResponseContentTypeName: "html", clientRequestHTTPMethodName: "GET", edgeResponseStatus: 200, clientRequestHTTPHost_in: ["developmentfinance.org", "www.developmentfinance.org"], clientRequestPath_like: "/prototypes%"}) { dimensions { date clientRequestPath verifiedBotCategory } count }
```

`page_loads` sums a day's groups for a path with an empty `verifiedBotCategory`, and `verified_bot_page_loads` the rest. The filter counts GET requests only, so HEAD requests from link checkers are left out. A capture that returns 1,000 groups may have been cut short, so split its range. Write the figures as JSON lines, one per day and path with `date`, `path`, `page_loads` and `verified_bot_page_loads`, and from the repository root run:

```sh
scripts/load-cloudflare-pages-history.sh <rows.jsonl> <start_date> <end_date>
```

The loader runs as the daily one does, replacing every day from start to end in `cloudflare_pages_daily` and creating the table on its first run. It refuses the same files and end dates, and also a row whose `path` is not a string starting with `/`. A day may hold many paths, and a day and path on more than one row is refused. Both loaders check their files with `wh_read_rows` in `scripts/web-history-lib.sh`.

## Website page views before the request log

The website's request log carries the status and bot fields that `website_requests_daily` reads from 2026-10-24. For the days before, `web_history.website_page_history` holds page views rebuilt from Cloud Run's own request log for `dfo-prod-website`, per UTC day from 2026-10-14 to 2026-10-23. Cloud Run's request log lives in the project's `_Default` log bucket, which keeps 30 days, so the capture reads a day only until 00:00 UTC thirty days after it (2026-10-14 until 2026-11-13).

`scripts/capture-website-page-history.sh <start_date> <end_date>` reads that log with `gcloud logging read`, one UTC day at a time, and classifies each request with `scripts/website-page-history-classify.mjs`, which runs the website's own bot test, isbot 5.2.2. It prints one JSON line per day with `date`, `page_views` and `bot_page_views`, and writes no URL or user agent to disk. A request counts as a page view when its host is `developmentfinance.org` or `www.developmentfinance.org`, its status is 2xx, and the website would log it as a page:

- a path under `/_next/` or ending in an asset extension is static, and left out;
- a path under `/api`, `/mcp`, `/openapi.json` or `/codes` is an API call, and left out;
- a URL with an `_rsc` query parameter, with or without a value, is an RSC request, and left out;
- any other request is a page.

`bot_page_views` counts the page views whose user agent isbot matches or that carry no user agent, and `page_views` the rest. 2026-10-14 counts from 06:21 UTC, when the public domain first reached the service, and holds 1,513 page views and 2,396 bot page views. The host filter leaves out the earlier preview-host traffic, including a crawler burst on the `run.app` host that day. 2026-10-15 to 2026-10-23 hold from 370 page views (2026-10-18) to 2,077 (2026-10-15), and 862 to 2,073 bot page views. The capture writes nothing, so it can be rerun at any time within retention. It refuses a start date older than today minus 29 days, whose first entries the bucket has already dropped, and fails a day that reads no entries. It needs `roles/logging.viewer` on the project, jq, and node with npm, which installs isbot 5.2.2 into a temporary directory with `npm ci`, from the lockfile in `scripts/website-page-history/` that pins it by integrity hash.

From the repository root, capture the range and load it:

```sh
scripts/capture-website-page-history.sh 2026-10-14 2026-10-23 > page-views.jsonl
scripts/load-website-page-history.sh page-views.jsonl 2026-10-14 2026-10-23
```

The loader runs as the same service account as the history loaders above and needs only `roles/iam.serviceAccountTokenCreator` on it. It replaces every day from start to end in `website_page_history`, creating the table on its first run, and refuses the same files as the Cloudflare loader. It refuses a start before 2026-10-14 and, as Cloudflare's does, an end after yesterday in UTC. It does not check the range against `website_requests_daily`, since `website_page_views_daily` takes history rows only for days before the request log's first parsed day, so overlapping days are safe to load and serve as a check.

On the days both logs cover, the rebuild gives 437 and 672 page views from people on 2026-10-24 and 2026-10-25, against 445 and 671 in `website_requests_daily`. The two count a few requests differently:

- The rebuild counts only the `developmentfinance.org` and `www.developmentfinance.org` hosts, and the request log counts every host the service answers, including the `run.app` host.
- A document request with `Sec-Purpose: prefetch` and no `prerender` counts as a page in the rebuild and as `prefetch` in the website's log.
- The rebuild finds RSC requests by the `_rsc` query parameter, and the website by the `rsc: 1` header.
- Cloud Run times a request when it arrives and the website when its response finishes, so a request that crosses midnight can fall on different days.
- The request log's parsed lines start at 00:04 UTC on 24 October 2026, so one page request answered between 00:00 and 00:04 UTC that day is in neither count.

## GA4 unique users

GA4's active users do not sum across days, since a visitor who returns counts on every day they visit. On 2026-10-24 the Data API gave 1,113 active users for 2026-10-05 to 2026-10-23, against 1,279 summed over the days. Two sources give unique users over a period, and both count only visitors who accepted analytics storage, as every GA4 user figure does.

- `ga4_daily`'s `users_sketch` is an HLL++ sketch of each export day's active users, so `HLL_COUNT.MERGE` over any window of export days gives its unique users, within HLL++ error. It covers the days from the GA4 export's first day, 2026-10-23, and is NULL on the history days before it, which the Data API reported only as counts.
- `ga4_user_ranges` holds the Data API's active, total and new users over fixed ranges, each user counted once per range. It covers every day GA4 holds, from 2026-10-14, but only the ranges asked for in advance. Each range ends at the data end, the earlier of yesterday and GA4's last day with data, since GA4 may not have processed yesterday when the run starts. The ranges are: since the floor, 2026-10-05, through the data end; the last 7 and the last 28 days ending at the data end; each ISO week, Monday to Sunday, and each calendar month from the floor's. The current week and month end at the data end, and one that would start after it, such as a Monday's week when GA4 holds only up to Sunday, is not asked for until a later run. No range is cut at the floor, so `last_28` is always 28 days and the first month starts on 2026-10-01. A range that ends before GA4's first day with data, such as the week of 2026-10-05, is not asked for either, so GA4 has a row for every range asked for. The request sets `keepEmptyRows`, so a range with no users returns a row of zeros instead of no row.

The Job `dfo-prod-analytics-ga4-user-ranges` ("Analytics jobs") fills `web_history.ga4_user_ranges` at 06:00 UTC every day and replaces the whole table on each run. GA4 keeps revising a day for 2 to 3 days, and each run rereads every range, so the revisions land on later runs. The analytics repository's `dfo_analytics.extract.ga4_user_ranges` holds the logic, and Terraform does not manage the table. To run it by hand:

```sh
gcloud run jobs execute dfo-prod-analytics-ga4-user-ranges --region europe-west1 --project prod-fin-observatory --wait
```

## Reporting tables

The analytics repository's scheduled dbt build writes the tables in `dfo_reporting` as `dfo-prod-analytics-runner`, the dataset's one writer, and that repository documents each table's columns and rules. The tables hold counts, sums, durations, sketches and route or page paths, and no user id, IP, raw conversation id or free text. This stack holds the dataset and its grants (`reporting.tf`) and none of its tables. Readers of `dfo_reporting` get no access to the datasets its tables are built from ("Readers").

## Edge request logs

`edge_logs.tf` creates `dfo-prod-edge-logs-prod-fin-observatory`, the bucket the edge-logs stack's Cloudflare Logpush job writes dataset-read request lines to, one gzipped NDJSON batch at a time under `http_requests/<YYYYMMDD>/`. The lines hold raw client IPs, so batches (`*.log.gz`) are deleted three days after they are written, which leaves time to repair a fault in the load into BigQuery and soft delete is off. Cloudflare's `logpush@cloudflare-data.iam.gserviceaccount.com` holds `roles/storage.objectAdmin` on the bucket. The planner holds no object grant on it, since no pull-request plan runs the edge-logs stack. Copy the `edge_logs_bucket` output into the edge-logs stack's `edge_logpush_bucket`. [`infra/dfo-prod/edge-logs/README.md`](../edge-logs/README.md) has the order to turn the job and the cache on, and [`infra/dfo-prod/edge/README.md`](../edge/README.md), "Logpush", the fields and the cost.

## Analytics repo

The private repository `DevelopmentFinanceObservatory/analytics` holds a dbt project that turns the raw usage data into usage metrics. Every metric's logic lives there. This stack holds only the datasets the project writes and the accounts that run it (`analytics.tf`). The project reads fifteen source datasets: `dfo_logs`, `website_export`, `langfuse_export`, the GA4 export (`analytics_556773461`), `searchconsole`, `billing_dfo`, `web_history`, `edge_export`, `studio_grades`, `repo_search`, `lighthouse`, `replay_probe`, `citation_probe`, `topics` and `langfuse_specs`. The last eight are written by the repository's own Python jobs ("Analytics jobs").

The billing account also bills projects outside DFO, so the project reads billing through `billing_dfo.costs`, a view over `billing_export.gcp_billing_export_v1_*` that keeps only the projects in `spend_callers` (`reporting.auto.tfvars`), labelled with their caller. The view is authorised on `billing_export`, and no account or developer here reads `billing_export` itself. `tests/billing_dfo_costs.test.sh` runs the view over literal rows.

Each dbt target writes one EU dataset:

| Dataset         | Written by                                              | Table expiration |
| --------------- | ------------------------------------------------------- | ---------------- |
| `analytics`     | `dfo-prod-analytics-runner`, the `prod` target          | none             |
| `analytics_ci`  | `dfo-prod-analytics-ci`, the `ci` target                | 1 day            |
| `analytics_dev` | analytics developers' own credentials, the `dev` target | 7 days           |

`dfo-prod-analytics-ci` runs the repository's `dbt-build` CI job. `dfo-prod-analytics-runner` runs the scheduled dbt build, the `dfo-prod-analytics-dbt` Job. Each account holds `roles/bigquery.jobUser` on the project, `WRITER` on its own dataset, and `READER` on the fifteen sources. The runner also writes `dfo_reporting` (see "Reporting tables"). A model the analytics repository places in any other dataset with `+schema` fails at build until `analytics.tf` grants the runner `WRITER` on that dataset.

The principals secret's `analytics_developers` object lists the people who build models against prod data. Each gets `roles/bigquery.jobUser` on the project, `READER` on the fifteen sources, and `WRITER` on `analytics_dev`. `dfo_logs` holds request IPs and user agents, so a developer reads those too. Someone who only reads the dashboard belongs in `readers` instead. Every developer builds into the one `analytics_dev` dataset, so the last build of a model replaces anyone else's. The analytics repository's `DBT_BIGQUERY_DEV_DATASET` variable points a developer's build at another dataset, which needs its own grant.

The CI job reaches `dfo-prod-analytics-ci` through Workload Identity Federation on the shared GitHub pool, so the account has no key. `analytics_ci_wif` admits only a run on `refs/heads/main`, keyed on `attribute.repo_ref` as `dfo-dev-sdk-e2e` is, since the account reads `dfo_logs` with its request IPs and user agents and a pull request must not mint a token for it. The `dbt-build` job queries BigQuery only on pushes to main. The pool's attribute condition admits only the repositories in `foundation`'s `github_repositories`, so the id (1464310463) sits in both stacks: the `analytics` entry in `infra/dfo-prod/foundation/env.auto.tfvars` and `analytics_repository_id` in this directory's `env.auto.tfvars`. Foundation and telemetry apply on merge. Where `analytics_repository_id` is null, the binding does not exist and the `dbt-build` job is skipped. After the apply, set the repository variables the job reads:

```sh
gh variable set GCP_WIF_PROVIDER --repo DevelopmentFinanceObservatory/analytics \
  --body "$(terraform -chdir=infra/dfo-prod/foundation output -raw workload_identity_provider)"
gh variable set GCP_CI_SERVICE_ACCOUNT --repo DevelopmentFinanceObservatory/analytics \
  --body dfo-prod-analytics-ci@prod-fin-observatory.iam.gserviceaccount.com
```

The repository's `Deploy` workflow pushes its job image to the Docker repository `analytics` in Artifact Registry (`europe-west1-docker.pkg.dev/prod-fin-observatory/analytics`, output `analytics_image_repository`) as `dfo-prod-analytics-deployer`, which holds `roles/artifactregistry.writer` on that repository and, with `analytics_jobs_enabled` on, the grants that move the Jobs to a new image ("Analytics jobs"). The repository keeps the ten newest images and deletes older tagged ones after 30 days. `analytics_deployer_wif` admits only a job on `refs/heads/main` that declares the `production` GitHub Environment, keyed on `attribute.repo_env_ref` as `dfo-ai-deployer` is, so a pull request cannot push an image. It shares `analytics_repository_id` with the CI binding and is absent while that is null. Give the analytics repository a `production` Environment whose deployment branch policy admits main alone, and set `GCP_DEPLOY_SERVICE_ACCOUNT` to the `analytics_deployer_service_account_email` output.

## Analytics jobs

Thirteen Cloud Run Jobs in `europe-west1` run the analytics repository's image, declared in `analytics_jobs.tf`. The image has no entrypoint, so each Job's args are its whole command line:

| Job                                   | Args                                                                      | Runs as                          | Schedule (UTC)                    | Task timeout | Memory |
| ------------------------------------- | ------------------------------------------------------------------------- | -------------------------------- | --------------------------------- | ------------ | ------ |
| `dfo-prod-analytics-dbt`              | `dbt build --target prod`                                                 | `dfo-prod-analytics-runner`      | hourly at minute 25               | 45 minutes   | 1 GiB  |
| `dfo-prod-analytics-edge`             | `python -m dfo_analytics.extract.edge`                                    | `dfo-prod-analytics-edge`        | hourly at minute 5                | 45 minutes   | 2 GiB  |
| `dfo-prod-analytics-grade`            | `python -m dfo_analytics.grade`                                           | `dfo-prod-analytics-grader`      | daily at 04:30                    | 60 minutes   | 1 GiB  |
| `dfo-prod-analytics-freshness`        | `dbt source freshness --target prod --project-dir dbt --profiles-dir dbt` | `dfo-prod-analytics-runner`      | hourly at minute 50               | 15 minutes   | 1 GiB  |
| `dfo-prod-analytics-repos`            | `python -m dfo_analytics.repos`                                           | `dfo-prod-analytics-repos`       | Mondays at 04:00                  | 60 minutes   | 1 GiB  |
| `dfo-prod-analytics-lighthouse`       | `python -m dfo_analytics.lighthouse`                                      | `dfo-prod-analytics-lighthouse`  | Mondays at 05:00                  | 3 hours      | 1 GiB  |
| `dfo-prod-analytics-replay`           | `python -m dfo_analytics.replay`                                          | `dfo-prod-analytics-replay`      | Mondays at 06:00                  | 60 minutes   | 1 GiB  |
| `dfo-prod-analytics-citations`        | `python -m dfo_analytics.citations`                                       | `dfo-prod-analytics-citations`   | 1st of the month at 06:00         | 24 hours     | 1 GiB  |
| `dfo-prod-analytics-topics-variables` | `python -m dfo_analytics.topics variables`                                | `dfo-prod-analytics-topic-vars`  | Mondays at 07:00                  | 60 minutes   | 2 GiB  |
| `dfo-prod-analytics-topics-turns`     | `python -m dfo_analytics.topics turns`                                    | `dfo-prod-analytics-topic-turns` | daily at 05:45                    | 60 minutes   | 2 GiB  |
| `dfo-prod-analytics-topics-specs`     | `python -m dfo_analytics.topics specs`                                    | `dfo-prod-analytics-topic-specs` | Daily at 08:00                    | 60 minutes   | 2 GiB  |
| `dfo-prod-analytics-call-specs`       | `python -m dfo_analytics.extract.observation_specs`                       | `dfo-prod-analytics-call-specs`  | hourly at minute 35, not 04 to 06 | 20 minutes   | 1 GiB  |
| `dfo-prod-analytics-ga4-user-ranges`  | `python -m dfo_analytics.extract.ga4_user_ranges`                         | `dfo-prod-analytics-ga4-ranges`  | daily at 06:00                    | 15 minutes   | 1 GiB  |

No Job retries a failed task, so the next scheduled run is the retry, and each timeout ends an execution before the next trigger. The edge extract runs at minute 5 so the build at minute 25 reads its load, and the freshness check at minute 50 reads the sources after both. The freshness Job exists only once `analytics_dbt_schedule_enabled` is on, since it checks the sources the scheduled build reads. The grade Job sets `GRADE_RUN_TIMEOUT_MINUTES` to 60 and its task timeout from the same number, so each run finds the last run's lease ended or lapsed. An edge object at the extract's 256 MiB cap peaks near 1.3 GiB, hence its 2 GiB. The Lighthouse probe makes 15 PageSpeed Insights calls in sequence, each up to 180 seconds with three tries, a worst case near 2.3 hours with backoff, so its timeout is 3 hours. The citation probe runs its three providers in parallel threads, each asking 60 times in sequence with each ask capped at 20 minutes; a month's run takes a few hours, and its 24-hour timeout ends only a pathological one.

The three topics Jobs run one command, `python -m dfo_analytics.topics`, with a pass as its argument: `variables` labels the DFO variables from the origin catalogue, `turns` labels the Studio turns in `langfuse_export` from the last 365 days, and `specs` labels the API specs callers use, from the request paths in `analytics.stg_log_lines` from 2026-10-24. The pass does not read `dfo_logs`. Its account is the only job account with `READER` on `analytics`, and `stg_log_lines` keeps the delivery lines' `json_payload`, which carries user agents and hashed IP caller ids (`ip:<hash>`). Each pass is its own Job with its own secrets, reads, invoker grant, alerts and timeout. The `turns` pass starts at 05:45, after the grader's 04:30 start and 60-minute timeout, so it reads the turns the grader has read. Each run labels at most 50,000 items (`TOPICS_MAX_ITEMS`), 10 calls at a time (`TOPICS_CONCURRENCY`); `variables` is capped at 20,000, since each of its requests carries about 2,000 input tokens and its rate is unmeasured, and `specs` makes one call at a time, since a members call can take one of the apis instance's two materialise permits and the door refuses 503 while both are held. The task timeout is 3600 s. Each run stops starting chunks 50 minutes in (`TOPICS_RUN_DEADLINE_MINUTES`) and exits 0. The `variables` and `turns` passes and the grader share the TypeSafe key, and `specs` calls no model, so `variables` starts on Mondays at 07:00, after the `turns` pass's start and timeout, and `specs` runs daily at 08:00. The Jobs read the dbt seed `dbt/seeds/topic_taxonomy.csv` from the image's `/app`. The Jobs write `topics`, an EU dataset in `analytics.tf` whose tables the Jobs create through the analytics repository's `ensure_table`, so Terraform declares none and the Jobs own the schemas. The analytics models over those tables need the tables to exist, so before any analytics change with models over `topics` merges, run the passes as "Bootstrapping the topics passes" gives and confirm all six tables exist: `variable_topics`, `turn_topics`, `spec_members`, `item_attempts`, `key_complete` and `catalogue_variables`. The `specs` pass resolves its first canary against the prod apis service, so it needs `dfo-prod-apis` serving the spec the image names in `BOOTSTRAP_SPEC`. The topics Jobs run in UTC like the others, so `turns` at 05:45 stays after the grader's timeout through the summer clock change.

The observation specs Job reads the Langfuse observations in `langfuse_export` for the environment `LANGFUSE_EXPORT_ENVIRONMENT` names and writes `langfuse_specs`, an EU dataset in `analytics.tf` whose table the Job creates, so Terraform declares none. It runs hourly at minute 35 except at 04:35, 05:35 and 06:35 (`35 0-3,7-23 * * *`), after the export (minute 0, 1,800 s timeout) has finished, so the dbt build at minute 25 reads the next hour's run; observations loaded later are registered on the next run. The Job shares the Langfuse key with the export and the grader, and its times keep them apart: a run's 20-minute deadline ends it by minute 55, clear of the export at minute 0, and the skipped hours keep it clear of the grader (04:30, 60-minute timeout) and the topics `turns` pass (05:45, 60-minute timeout). Its task timeout of 20 minutes ends any run by minute 55, before the export starts. The Job creates its table, so it needs bootstrapping before the analytics dbt change that reads `langfuse_specs.observation_specs` merges. The apply creates the Job from `analytics_jobs_image`, an image that holds `dfo_analytics.extract.observation_specs`. Add `dfo-prod-analytics-call-specs` to the analytics repository variable `ANALYTICS_JOBS`, so its `Deploy` workflow moves the Job with the others. Then run `gcloud run jobs execute dfo-prod-analytics-call-specs --region europe-west1 --project prod-fin-observatory --wait` once, confirm `langfuse_specs.observation_specs` holds `read` rows, and switch the `call-specs` key on within five hours of that run, the window its absence alert reads.

The edge extract writes `edge_export` and the grader `studio_grades`, two EU datasets in `analytics.tf`. The grader creates its own tables. `analytics.tf` declares the extract's three, `edge_export.deliveries`, `loaded_objects` and `runs`, whatever `analytics_jobs_enabled` says, so the first dbt build finds the sources it names. Each copies the extract's schema, partitioning and clustering exactly: `deliveries` is day-partitioned on `edge_started_at` and clustered on `spec_id`, `loaded_objects` is day-partitioned on `loaded_at`, and `runs` is unpartitioned. The extract creates a table only when it is absent, and refuses to run on one whose columns differ from its own in name, type, mode or order, so a schema change in `dfo_analytics/extract/edge.py` needs the same change here first. The tables keep deletion protection.

The four probes write four more EU datasets in `analytics.tf`, each with tables Terraform declares whatever `analytics_jobs_enabled` says, since the analytics changes that add each probe build dbt models over them and the citation probe refuses to run on a missing table:

| Dataset          | Written by                      | Tables                 | Source in the analytics repository                                    |
| ---------------- | ------------------------------- | ---------------------- | --------------------------------------------------------------------- |
| `repo_search`    | `dfo-prod-analytics-repos`      | `matches`, `runs`      | `SCHEMA`, `RUNS_SCHEMA` in `dfo_analytics/repos/job.py`               |
| `lighthouse`     | `dfo-prod-analytics-lighthouse` | `results`, `runs`      | `RESULTS_SCHEMA`, `RUNS_SCHEMA` in `dfo_analytics/lighthouse/job.py`  |
| `replay_probe`   | `dfo-prod-analytics-replay`     | `slot_results`, `runs` | `SLOT_RESULTS_SCHEMA`, `RUNS_SCHEMA` in `dfo_analytics/replay/job.py` |
| `citation_probe` | `dfo-prod-analytics-citations`  | `answers`, `runs`      | `ANSWERS_SCHEMA`, `RUNS_SCHEMA` in `dfo_analytics/citations/job.py`   |

Each table copies its job's schema column for column and in order, with BigQuery's legacy type names for `INT64`, `FLOAT64` and `BOOL`, and is day-partitioned on its run time column (`run_started_at` for the replay tables, `run_at` for the rest) and unclustered, as the job's own `TimePartitioning` is. A job creates a table only when it is absent and appends with its own schema, which a load job refuses where a mode differs, and the replay probe refuses to run on a table whose types or modes differ, so a schema change in the analytics repository needs the same change here first. The tables keep deletion protection.

Each Job has its own account, `dfo-prod-analytics-edge`, `dfo-prod-analytics-grader`, `dfo-prod-analytics-repos`, `dfo-prod-analytics-lighthouse`, `dfo-prod-analytics-replay` and `dfo-prod-analytics-citations`, with `roles/bigquery.jobUser` on the project and `WRITER` on its dataset alone. The grader also holds `READER` on `langfuse_export`, the turns it grades. The three topics accounts, `dfo-prod-analytics-topic-vars`, `dfo-prod-analytics-topic-turns` and `dfo-prod-analytics-topic-specs` (service account ids allow 30 characters), each hold `WRITER` on `topics`; `topic-turns` also holds `READER` on `langfuse_export`, and `topic-specs` holds `READER` on `analytics`, whose `stg_log_lines` it reads. The observation specs account, `dfo-prod-analytics-call-specs`, holds `WRITER` on `langfuse_specs` and `READER` on `langfuse_export`. The GA4 user ranges account, `dfo-prod-analytics-ga4-ranges`, holds `WRITER` on `web_history` (`history.tf`), which the history loaders' account also writes, and GA4 Viewer on the property, granted by hand ("Web history before the exports"). All eight job datasets and `web_history` are analytics sources, so the runner, the CI account and the analytics developers read them. The datasets, the eleven accounts and these grants exist whatever `analytics_jobs_enabled` says, since the analytics changes that write the datasets need them first.

The edge extract reads `EDGE_LOGS_BUCKET` (`dfo-prod-edge-logs-prod-fin-observatory`, the bucket Cloudflare Logpush writes to, on which its account holds `roles/storage.objectViewer`), `EXPORT_BQ_PROJECT` and `EDGE_EXPORT_DATASET`, and `CALLER_HMAC_KEY` from the secret `dfo-prod-caller-hmac-key`, the key the website and dfo-apis use, so one client carries one caller in all three. The grader reads `GRADE_BQ_PROJECT`, `GRADE_SOURCE_DATASET`, `GRADE_DATASET`, `GRADE_RUN_TIMEOUT_MINUTES`, `LANGFUSE_BASE_URL` (`https://cloud.langfuse.com`) and `LANGFUSE_EXPORT_ENVIRONMENT` (`dfo-prod-ai`, the environment the ai service tags its traces with), with `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` from `dfo-prod-langfuse-public-key` and `dfo-prod-langfuse-secret-key`, the pair the ai service exports with, and the key of the decision backend `analytics_grade_decision_backend` selects (`GRADE_DECISION_BACKEND`): `TYPESAFE_API_KEY` from `dfo-prod-analytics-grader-typesafe-api-key` for Jev, the default, or `GOOGLE_API_KEY` from `dfo-prod-analytics-grader-gemini-api-key` for Gemini. The Job mounts the selected backend's key alone. The topics `variables` and `turns` Jobs mount the grader's TypeSafe key as well (`specs` calls no model), so it needs a live version whatever backend is selected. The topics Jobs read `TOPICS_BQ_PROJECT`, `TOPICS_DATASET` (`topics`), `TOPICS_CONCURRENCY`, `TOPICS_MAX_ITEMS` and `TOPICS_RUN_DEADLINE_MINUTES` (50), and leave `TOPICS_TAXONOMY_PATH` unset, so the Jobs read `dbt/seeds/topic_taxonomy.csv` from the image's `/app`. `variables` also reads `TOPICS_CATALOGUE_BUCKET` (`dfo-prod-origin-catalogue-prod-fin-observatory`, the apis stack's origin catalogue bucket, on which `topic-vars` holds `roles/storage.objectViewer`). `turns` reads `TOPICS_SOURCE_DATASET` (`langfuse_export`), `TOPICS_TURN_LOOKBACK_DAYS` (365), `LANGFUSE_BASE_URL` and `LANGFUSE_EXPORT_ENVIRONMENT` as the grader does. `specs` reads `TOPICS_APIS_URL` and `TOPICS_APIS_AUDIENCE`, the apis service's URL as for the replay probe, `TOPICS_SPEC_SERVICES` (the apis service, `dfo-prod-apis`, and `dfo-prod-website`, comma-separated), and `TOPICS_ANALYTICS_DATASET` (`analytics`). The observation specs Job reads `SPECS_BQ_PROJECT`, `SPECS_SOURCE_DATASET` (`langfuse_export`), `SPECS_DATASET` (`langfuse_specs`), `LANGFUSE_BASE_URL` and `LANGFUSE_EXPORT_ENVIRONMENT` as the grader does, with `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` from the same two secrets. The GA4 user ranges Job replaces `web_history.ga4_user_ranges` whole ("GA4 unique users") and reads `GA4_USER_RANGES_GA4_PROPERTY` (the GA4 property id, `ga4_export_dataset` without its `analytics_` prefix), `GA4_USER_RANGES_PROJECT` (`prod-fin-observatory`), `GA4_USER_RANGES_LOCATION` (`EU`) and `GA4_USER_RANGES_FLOOR` (2026-10-05, the site's launch day). The probes read their project and dataset from `REPO_SEARCH_BQ_PROJECT` and `REPO_SEARCH_DATASET`, `LIGHTHOUSE_BQ_PROJECT` and `LIGHTHOUSE_DATASET`, `REPLAY_BQ_PROJECT` and `REPLAY_DATASET`, and `CITATION_PROBE_BQ_PROJECT` and `CITATION_PROBE_DATASET`, and their keys from secrets of their own:

| Job                                   | Variable                                     | Secret                                                         |
| ------------------------------------- | -------------------------------------------- | -------------------------------------------------------------- |
| `dfo-prod-analytics-repos`            | `GITHUB_TOKEN`                               | `dfo-prod-analytics-repos-github-token`                        |
| `dfo-prod-analytics-lighthouse`       | `PSI_API_KEY`                                | `dfo-prod-analytics-lighthouse-psi-api-key`                    |
| `dfo-prod-analytics-replay`           | `VERIFY_PRINCIPAL`                           | `dfo-prod-verify-principal`, from the apis stack               |
| `dfo-prod-analytics-replay`           | `EXPORT_ID_HMAC_KEY`                         | `dfo-prod-website-export-hmac-key`, from the website stack     |
| `dfo-prod-analytics-citations`        | `OPENAI_API_KEY`                             | `dfo-prod-analytics-citations-openai-api-key`                  |
| `dfo-prod-analytics-citations`        | `GEMINI_API_KEY`                             | `dfo-prod-analytics-citations-gemini-api-key`                  |
| `dfo-prod-analytics-topics-variables` | `TYPESAFE_API_KEY`                           | `dfo-prod-analytics-grader-typesafe-api-key`, the grader's     |
| `dfo-prod-analytics-topics-turns`     | `TYPESAFE_API_KEY`                           | `dfo-prod-analytics-grader-typesafe-api-key`, the grader's     |
| `dfo-prod-analytics-topics-turns`     | `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` | `dfo-prod-langfuse-public-key`, `dfo-prod-langfuse-secret-key` |
| `dfo-prod-analytics-call-specs`       | `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` | `dfo-prod-langfuse-public-key`, `dfo-prod-langfuse-secret-key` |

The replay probe calls `dfo-prod-apis` at `REPLAY_APIS_BASE_URL`, the service's deterministic URL (`https://dfo-prod-apis-<project number>.europe-west1.run.app`), with an ID token whose audience, `REPLAY_ID_TOKEN_AUDIENCE`, is the same URL, since the service admits only callers holding `roles/run.invoker`. Its account holds that role on `dfo-prod-apis` (`analytics_replay_apis_invoker`) while the Job exists, and `topic-specs` holds it too (`analytics_topics_apis_invoker`) for the `specs` Job. `VERIFY_PRINCIPAL` is the verify principal, the one value that opens dfo-apis' analysis verify route and Presentation share sample, which the apis stack generates and mounts on the service ("Verify principal" in `infra/dfo-dev/apis/README.md`). `EXPORT_ID_HMAC_KEY` is the website event export's key, so a `share_digest` in `replay_probe` equals the export's digest of the same `shareId`.

Each account holds `roles/secretmanager.secretAccessor` on the secrets its Job mounts and no other, and a Job reads each secret's latest version when an execution starts. Terraform declares the two grader key secrets and the five probe key secrets (`dfo-prod-analytics-repos-github-token`, `dfo-prod-analytics-lighthouse-psi-api-key`, and the three `dfo-prod-analytics-citations-*-api-key`) with no version, so each key goes in by hand before the Jobs exist. The verify principal and the export key are generated by their stacks.

Terraform creates each Job with the image in `analytics_jobs_image`, a sha-tagged image from the analytics registry, and then ignores the Job's image, so a deploy moves the Jobs without reading as drift. `dfo-prod-analytics-deployer` holds `roles/run.developer` on each Job and `roles/iam.serviceAccountUser` on each Job's account, which `gcloud run jobs update <job> --image <image> --region europe-west1 --project prod-fin-observatory` needs. The analytics repository's `Deploy` workflow runs that update after each push for every Job named in its repository variable `ANALYTICS_JOBS` (DevelopmentFinanceObservatory/analytics#7). Set the variable to the twelve Jobs' names once they exist, `dfo-prod-analytics-dbt dfo-prod-analytics-edge dfo-prod-analytics-grade dfo-prod-analytics-repos dfo-prod-analytics-lighthouse dfo-prod-analytics-replay dfo-prod-analytics-citations dfo-prod-analytics-topics-variables dfo-prod-analytics-topics-turns dfo-prod-analytics-topics-specs dfo-prod-analytics-call-specs dfo-prod-analytics-ga4-user-ranges`; until then a Job keeps the image it was created with. The freshness Job exists only once `analytics_dbt_schedule_enabled` is on, and a named Job that does not exist fails the deploy, so add `dfo-prod-analytics-freshness` to the variable after that apply.

Cloud Scheduler starts each Job as `dfo-prod-analytics-scheduler`, which holds `roles/run.invoker` on each Job and nothing else, through the triggers `dfo-prod-analytics-dbt-tick`, `dfo-prod-analytics-edge-tick`, `dfo-prod-analytics-grade-tick`, `dfo-prod-analytics-freshness-tick`, `dfo-prod-analytics-repos-tick`, `dfo-prod-analytics-lighthouse-tick`, `dfo-prod-analytics-replay-tick`, `dfo-prod-analytics-citations-tick`, `dfo-prod-analytics-topics-variables-tick`, `dfo-prod-analytics-topics-turns-tick`, `dfo-prod-analytics-topics-specs-tick`, `dfo-prod-analytics-call-specs-tick` and `dfo-prod-analytics-ga4-user-ranges-tick`. The dbt trigger exists only once `analytics_dbt_schedule_enabled` is true. A probe's trigger exists only while its entry in the map `analytics_probes_enabled` is true; every entry defaults to false, so each probe's Job exists with no trigger and no absence alert until its switch is on. The map's keys are `repos`, `lighthouse`, `replay`, `citations`, `topics-variables`, `topics-turns`, `topics-specs` and `call-specs`. The first three of the last four are the topics passes and `call-specs` is the observation specs Job; all four are switched on like probes after a canary execution, and the map needs `analytics_jobs_enabled`.

To run a Job outside its schedule, or with other args or settings, start one execution. Overrides need `run.jobs.runWithOverrides` on the Job, which a project owner holds:

```sh
gcloud run jobs execute dfo-prod-analytics-dbt --region europe-west1 --project prod-fin-observatory --wait \
  --args='dbt,build,--target,prod,--select,requests_daily'
```

`--args` takes the whole command line, comma-separated. `--update-env-vars` sets a setting for that execution alone, such as `DBT_MAXIMUM_BYTES_BILLED` for a dbt run that reads more than 20 GB, or `EDGE_REJECT_OBJECTS` for an edge run that moves past a held batch. The extract records a rejected object, so one execution is enough.

### Switching the Jobs on

1. Apply this stack with `analytics_jobs_enabled` false, which creates `edge_export` and its three tables, `studio_grades`, the four probe datasets and their tables, the empty `topics` and `langfuse_specs` datasets, the ten Job accounts and their dataset grants, and the empty Gemini and probe key secrets. The apis stack applies first and creates `dfo-prod-verify-principal`.

2. Add the grader's TypeSafe key as the secret's first version, with `gcloud secrets versions add dfo-prod-analytics-grader-typesafe-api-key --data-file=- --project=prod-fin-observatory` reading the key from stdin, and each probe key the same way: a GitHub token that may search public code to `dfo-prod-analytics-repos-github-token`, a PageSpeed Insights API key to `dfo-prod-analytics-lighthouse-psi-api-key`, and the OpenAI and Gemini keys to `dfo-prod-analytics-citations-openai-api-key` and `dfo-prod-analytics-citations-gemini-api-key`. The citation probe skips a provider whose key is unset, and the Job mounts no Anthropic key, so it asks OpenAI and Gemini. The edge logs bucket must exist, with the edge-logs stack's Logpush job writing to it.

3. Merge the analytics changes that add the edge extract, the turn grader and the four probes, and let the `Deploy` workflow push the image. Note its sha. The replay probe also needs the dfo-apis release that adds the verify route and the share sample.

4. Set `analytics_jobs_enabled = true` and `analytics_jobs_image = "europe-west1-docker.pkg.dev/prod-fin-observatory/analytics/dfo-analytics:<sha>"` in `env.auto.tfvars`, merge, and let the apply run. It creates every Job in the table under "Analytics jobs" except freshness (the output `analytics_job_names` lists them), the edge and grade triggers, their alerts, the edge object alert, the call-specs lost-rows metric and its alert, and the invoker grants on `dfo-prod-apis` for the replay and topics `specs` accounts, and no dbt trigger, probe trigger or freshness Job. The grade absence alert opens within minutes; run `gcloud run jobs execute dfo-prod-analytics-grade --region europe-west1 --project prod-fin-observatory` to close it. The probes have no trigger and no absence alert yet, since `analytics_probes_enabled` is false for each; their canary executions and switches follow in "Switching a probe on". Each probe's canary also fills its source table, which `dbt source freshness` needs before step 5: it errors on an empty table.

5. Check that each probe's canary execution has succeeded, then set `analytics_dbt_schedule_enabled = true`, merge, and let the apply run. It creates the dbt trigger and its alert, and the freshness Job, its trigger and its alert.

### Switching a probe on

Each probe is switched on alone, in this order, with the probe's entry in `analytics_probes_enabled` (`repos`, `lighthouse`, `replay`, `citations`, `topics-variables`, `topics-turns`, `topics-specs` or `call-specs`) as the last step. Until then the Job, its account, its secrets and its tables exist and a manual execution works, and the probe has no trigger and no absence alert.

1. Set the probe's secret values (the table under "Analytics jobs": the GitHub token for `repos`, the PageSpeed Insights key for `lighthouse`, the three provider keys for `citations`; `replay` mounts the verify principal and the export key, which the apis and website stacks generate; the topics passes mount keys that already exist; `call-specs` mounts `dfo-prod-langfuse-public-key` and `dfo-prod-langfuse-secret-key`, the pair the grader and the topics `turns` pass mount, so it needs no new secret).

2. Build the image from the analytics repository's `Deploy` workflow with the probe's code, and set `analytics_jobs_image` to it, or move the Job with `gcloud run jobs update <job> --image <image> --region europe-west1 --project prod-fin-observatory`.

3. Run one canary: `gcloud run jobs execute <job> --region europe-west1 --project prod-fin-observatory --wait` (add `--async` for `dfo-prod-analytics-citations`, which takes a few hours). Check three things:

   - The execution exits 0.
   - The probe's tables hold rows for the expected inputs: for `repos`, `repo_search.runs` has a row for each query; for `lighthouse`, `lighthouse.results` has a row for each attempt on each of the 5 URLs (15 rows) and `lighthouse.runs` records the run; for `replay`, `replay_probe.runs` has a row for the run whose status is not a failure, and `slot_results` has rows for the shares sampled; for `call-specs`, `langfuse_specs.observation_specs` holds `read` rows; for the topics passes, the bootstrap below has run and `topics.variable_topics` (`topics-variables`), `topics.turn_topics` (`topics-turns`) or `topics.spec_members` (`topics-specs`) holds rows; for `citations`, `citation_probe.runs` has a row for each provider and question and `answers` has a row for each answered ask.
   - The results are valid: no error or failure columns set where the run succeeded, a plausible number of rows, and values in range (for example Lighthouse scores between 0 and 1, and `answer_text` filled for each citation answer).

4. Set the probe's entry to true in `analytics_probes_enabled` in `env.auto.tfvars`, merge, and let the apply run. It creates the probe's trigger and its absence alert.

### Bootstrapping the topics passes

The three topics passes start with every item pending, and a scheduled run labels at most `TOPICS_MAX_ITEMS` of them (20,000 for `variables`, 50,000 for the others) before it exits 0. Label the backlog by hand, in this order, before any topics schedule exists.

1. Set `analytics_jobs_image` in `env.auto.tfvars` to the image of the analytics merge that adds the topics Jobs and the `catalogue_variables` table, merge, and let the apply run. Jobs ignore later image changes, so a Job created earlier takes the image with `gcloud run jobs update <job> --image <image> --region europe-west1 --project prod-fin-observatory`. Add the three topics Job names to the repository variable `ANALYTICS_JOBS` only after the bootstrap below has finished, so a later deploy does not move a Job while a pass is part way through.

2. Run `dfo-prod-analytics-topics-variables` one execution at a time, each with `--wait`: `gcloud run jobs execute dfo-prod-analytics-topics-variables --region europe-west1 --project prod-fin-observatory --wait`. About 202,000 variables at 20,000 a run take at least 11 executions. Stop when `topics.key_complete` holds a row with a `catalogue_build` for the current variables key, which a run writes only when no variable is pending under that key:

   ```sql
   SELECT taxonomy_version, model, prompt_hash, catalogue_build, completed_at
   FROM `prod-fin-observatory.topics.key_complete`
   WHERE catalogue_build IS NOT NULL
   ORDER BY completed_at DESC
   LIMIT 1
   ```

   An execution that exits 1 stopped on an outage or a rejected key; read its log before running another.

3. Run `dfo-prod-analytics-topics-specs` with `--wait` until an execution's log shows no items left pending, then `dfo-prod-analytics-topics-turns` the same way.

4. Check that all six tables hold rows: `variable_topics`, `turn_topics`, `spec_members`, `item_attempts`, `key_complete` and `catalogue_variables`. `catalogue_variables` holds one row for each variable in the catalogue build `key_complete` names.

5. Add `dfo-prod-analytics-topics-variables`, `dfo-prod-analytics-topics-turns` and `dfo-prod-analytics-topics-specs` to `ANALYTICS_JOBS`, if "Switching the Jobs on" has not already.

6. Switch each pass on with its entry in `analytics_probes_enabled`, only after the analytics models over `topics` have a passing prod dbt build. The schedules, in UTC, are `turns` daily at 05:45, `variables` on Mondays at 07:00 and `specs` daily at 08:00.

## Readers

The principals secret's `readers` object lists the readers of `dfo_reporting` as people, each `group:` or `user:` followed by an address. Each gets `READER` on `dfo_reporting`, and `roles/bigquery.jobUser` and `roles/mcp.toolUser` on the project, and no access to `dfo_logs`, `searchconsole`, or any other source dataset.

Readers and analytics developers share one `roles/bigquery.jobUser` grant per label, `people_job_user` in `main.tf`, since IAM holds one binding per member and role. A person in both objects carries the same label in each, so removing them from one keeps the role while the other lists them. Plan fails on a label that names different members in the two objects, or a member under two labels. The grant was `reporting_readers_job_user` in `reporting.tf`, and a `moved` block in `main.tf` carries the readers' live bindings over, so the plan that introduces it shows each reader's grant moved with no change, and a create only for each developer whose label is not already a reader's.

## Principals secret

The readers, analytics developers and alert recipients live in the Secret Manager secret `dfo-prod-telemetry-principals`. Prod plans run in public GitHub Actions logs, and every value from the secret prints there as `(sensitive value)`. `readers` and `analytics_developers` hold people (`group:` or `user:` followed by an address), and `alerts` at least one bare address. A service account gets its own Terraform resource in the stack that owns it, as [`infra/modules/principals-secret/README.md`](../../modules/principals-secret/README.md) states:

```json
{
  "readers": { "team": "group:readers@example.org" },
  "analytics_developers": { "dev-1": "user:dev1@example.org" },
  "alerts": { "team": "alerts@example.org" }
}
```

To create the secret, follow "Writing the secret" in [`infra/modules/principals-secret/README.md`](../../modules/principals-secret/README.md), with `prod-fin-observatory` and `dfo-prod-telemetry-principals`. To change its members, run `scripts/bootstrap-principals.sh edit prod-fin-observatory dfo-prod-telemetry-principals`. Then dispatch the apply with `--ref main` and `stack=telemetry`. That page also states the rules the secret must meet and the relabel order.

Plan fails while the secret's keys differ from the schema in `infra/modules/principals-secret/schemas.json`. A PR that adds a key to the telemetry schema, such as `analytics_developers`, lands in the order "Adding a key" gives in [`infra/modules/principals-secret/README.md`](../../modules/principals-secret/README.md), with `scripts/bootstrap-principals.sh edit prod-fin-observatory dfo-prod-telemetry-principals` as the edit step. Between that edit and the merge, every other telemetry plan and apply on `main` fails, since `main`'s schema lacks the key, so merge promptly. Members go in with a later `edit` and apply, once the key is on `main`.

## Apply order

Telemetry applies after `foundation`, which lets the applier write this stack's state.

## Made by hand first

- A local backend init, `just ENV=dfo-prod STACK=telemetry bootstrap`, once `foundation` has applied.
- The principals secret `dfo-prod-telemetry-principals`, written with `scripts/bootstrap-principals.sh` as "Principals secret" describes. Plan fails while it does not exist.
- The Google groups the secret names. The reader grants fail while a reader group does not exist, and an alert group must accept mail from outside its domain, since Cloud Monitoring sends from a google.com address.

## After the first apply

- The analytics repository's id in both stacks and its two repository variables, as "Analytics repo" shows. The repository's `dbt-build` job is skipped until then.
- The analytics Jobs, switched on in the order "Switching the Jobs on" gives.
- In Search Console, under Settings, Bulk data export, a property owner of developmentfinance.org enters the project `prod-fin-observatory`, the dataset `searchconsole`, and the location EU. The first export arrives within 48 hours.
