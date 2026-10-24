# telemetry (prod)

Prod's telemetry plumbing in BigQuery, which the team dashboard reads through the `dfo_reporting` dataset. The stack routes Cloud Run logs into a Log Analytics bucket, holds a one-off copy of the Cloud Run logs from before that route started, aggregates both daily into `logs_daily`, holds the dataset Search Console exports into, builds the reporting views in `dfo_reporting`, and grants readers access to it. The `.tf` files and the `sql` directory are symlinks to `infra/stacks/telemetry`. This directory holds prod's backend, tfvars, and lock file. The stack exists in prod only.

Every dataset is in the EU multi-region. Every dataset-level grant is a `google_bigquery_dataset_access`, and no dataset declares `access` blocks. Authoritative blocks, or `google_bigquery_dataset_iam_*` resources, would remove the other entries on the next apply, including the authorised-view entries the reporting views need on their sources.

## Logs

The sink `dfo-prod-telemetry` copies every `cloud_run_revision` and `cloud_run_job` entry from the `run.googleapis.com/requests`, `stdout` and `stderr` logs into the bucket `dfo-prod-telemetry` in `eu`, which keeps them for `log_retention_days` (30). The `_Default` bucket also receives the same entries. The filter names resource types and log ids, so a new or renamed service is routed with no change here. It leaves out the website's usage-event lines (`jsonPayload.message="event"` on `dfo-prod-website`'s stdout). They repeat the Postgres `event` table, which is the events source the website export copies, and their props carry the first 500 characters of each search query.

The bucket's linked dataset `dfo_logs` exposes the entries to BigQuery as the view `dfo_logs._AllLogs`. The entries hold request IPs and user agents. BigQuery roles decide who can read them. The `dfo-prod-logs-daily` service account reads `dfo_logs` through its dataset grant. Any principal with a project-level BigQuery data role reads it too. Those are the applier (`roles/bigquery.dataOwner`), `dfo-prod-dc-ing-pst-sa` (`roles/bigquery.dataEditor`), and the project owners. If the linked dataset carries BigQuery's default `projectWriters` and `projectReaders` entries, as datasets Terraform creates here do, the project's editors and viewers read it as well. Those are the default compute service account and the Google APIs service agent (`roles/editor`) and `dfo-infra-planner` (`roles/viewer`).

A sink routes only entries written after it exists, and this one routes every entry only from about 18:50 UTC on 2026-10-23. `logs_daily` therefore reads `dfo_logs` from a cut-off of 2026-10-23 19:00:00 UTC, and the backfill below before it.

## Backfill

`logs_daily.backfill_entries` holds the Cloud Run request, stdout and stderr entries from `_Default` before the cut-off, from 2026-10-05 on. It keeps the columns `sql/logs_daily.sql` reads, and only the `logger` field of each payload, so it holds no message text, IP or user agent. Request URLs keep their query strings. Every principal that reads `logs_daily` reads it.

The view `logs_daily.entries` (`sql/entries.sql`) reads `backfill_entries` before the cut-off and `dfo_logs._AllLogs` from it on, so no entry appears twice or goes missing. The cut-off is the one line of `logs_backfill_cutoff.txt`, which Terraform and the loader both read. `dfo-prod-logs-daily` reads the view through its `WRITER` grant on `logs_daily` and its `READER` grant on `dfo_logs`.

The bucket `gs://prod-fin-observatory-logs-backfill` (EU, objects deleted 14 days after they are written) holds `gcloud logging copy` output from `_Default`, filtered to `(resource.type="cloud_run_revision" OR resource.type="cloud_run_job")`. `scripts/load-logs-backfill.sh` loads it into `backfill_entries`, and its header lists what it checks before loading. `--ignore-operation` names a cancelled copy whose range a later copy repeats:

```sh
scripts/load-logs-backfill.sh --ignore-operation=CAESEzkwNzkxOTQ2NTY4NDM4MzI2NDg \
  prod-fin-observatory dfo-prod gs://prod-fin-observatory-logs-backfill
```

`backfill_entries` holds no message text, so the scheduled query cannot count the MCP lines before the cut-off. `mcp_daily` therefore has two writers, which write disjoint days. The scheduled query writes the days after the cut-off day. The loader writes the days through the cut-off day, and a rebuild of those days needs the loader run again over a kept copy. Before it loads staging, the loader runs `sql/mcp_daily_preflight.sql`. Once staging is loaded, it runs `sql/mcp_daily_history.sql` as one BigQuery script, before it replaces `backfill_entries`, so a refusal in that step stops the run with both tables as they were. Any other failure of the step stops the run before `backfill_entries` is replaced and leaves `mcp_daily` as it was, unless the step's transaction committed before the error, in which case its days were replaced. The script deletes `mcp_daily`'s days from the day after the oldest staged `stdout` or `stderr` entry, the two logs the parse reads, through the cut-off day and inserts the aggregate of the staged entries before the cut-off, with the messages of the combined MCP server's lines and no other message, and `dfo_logs._AllLogs` from the cut-off to the end of that day. The copy cut the oldest day of those logs part way through, so that day and every earlier one stay as they are, whatever day the `requests` folder starts. The script checks again, before any write, that `dfo_logs` reaches back to the cut-off, since retention can move between the preflight and the step. The script assumes the copy runs to the cut-off, as `backfill_entries` does, so a copy that stops between `dfo_logs`' oldest entry and the cut-off leaves those minutes uncounted. Both writers parse each line with the function `logs_daily.parse_mcp_line` (`sql/parse_mcp_line.sql`). The message text exists only inside the script's query and its temp tables, which the script drops when it succeeds. A failed run's temp tables hold MCP lines with their callers and expire with the script's session within 24 hours, as staging expires within a day. The loader prints the MCP calls it wrote per day, over that range and no other day. If the loader cannot read that report after the step commits, `mcp_daily` is written, `backfill_entries` is not replaced, and the loader exits 1 saying so.

The loader runs only once the `sql/logs_daily.sql` that keeps the scheduled query's `mcp_daily` DELETE after the cut-off day is applied in prod, since an older query's next run can delete the loader's days. Before any write the loader refuses unless the deployed `dfo-prod-logs-daily` query calls `logs_daily.parse_mcp_line`, which arrives with the same apply, and holds the cut-off of `infra/stacks/telemetry/logs_backfill_cutoff.txt` as `TIMESTAMP '<cut-off>'`, so that the two writers cannot disagree on the boundary. The loader trims the file's whitespace as Terraform does. It also refuses a copy without a `stderr` folder, where the combined MCP server logs its call lines. `--skip-mcp-daily` leaves out the `mcp_daily` step and these checks and replaces `backfill_entries` alone, for a copy the step refuses. The headers of `sql/mcp_daily_preflight.sql` and `sql/mcp_daily_history.sql` list the step's other refusals, each with a code `mcp_history:<code>:`.

The loader and the scheduled query both run DML on `mcp_daily`, and BigQuery aborts one of two overlapping transactions, so they do not run at the same time. Do not run the loader around 02:00 UTC or during a manual run of `dfo-prod-logs-daily`.

`_Default` keeps entries 30 days. Once the bucket's objects and those entries have expired, the loader's `mcp_daily` rows are the only copy of the days through the cut-off day. Emptying or recreating `mcp_daily` then loses those days, unless the loader runs again while a copy still exists, either the bucket objects or a fresh `gcloud logging copy` from `_Default`, and while `dfo_logs` still reaches the cut-off.

`infra/stacks/telemetry/tests/backfill_entries.test.sh` runs `sql/backfill_entries.sql` over literal entries. Run it after changing the query.

### Rebuilding logs_daily from the backfill

`requests_daily`, `routes_daily`, `errors_daily`, `mcp_daily` and `website_requests_daily` reload only from `requests_daily`'s latest day minus one, and `deploys` never changes a row, so the tables written before the load hold no backfill days and time each revision against `dfo_logs` alone. After the first load, and after any reload, empty the five tables below and run the query once. `mcp_daily` stays as it is, since the query replaces its days after the cut-off day itself and the loader owns the days through it, as "Backfill" describes. With `requests_daily` empty it loads from the backfill's oldest whole day, and `deploys` computes `before_source` against the longer source. Once retention has moved `dfo_logs`' oldest entry past the cut-off, a rebuild leaves out the days from the cut-off day through that entry's day, since neither source still holds them whole, so the four emptied daily tables lose those days for good. `mcp_daily`'s DELETE starts after that gap, so it keeps the rows it holds for those days.

```sh
bq query --project_id=prod-fin-observatory --location=EU --use_legacy_sql=false \
  'TRUNCATE TABLE `prod-fin-observatory.logs_daily.requests_daily`;
   TRUNCATE TABLE `prod-fin-observatory.logs_daily.routes_daily`;
   TRUNCATE TABLE `prod-fin-observatory.logs_daily.errors_daily`;
   TRUNCATE TABLE `prod-fin-observatory.logs_daily.deploys`;
   TRUNCATE TABLE `prod-fin-observatory.logs_daily.website_requests_daily`;'
config="$(bq ls --transfer_config --transfer_location=EU --project_id=prod-fin-observatory --format=json |
  jq -r '.[] | select(.displayName == "dfo-prod-logs-daily") | .name')"
bq mk --transfer_run --run_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$config"
```

The run's progress shows on the BigQuery console's Scheduled queries page. The dashboard reads empty tables between the truncate and the run's end.

## logs_daily

The scheduled query `dfo-prod-logs-daily` runs `sql/logs_daily.sql` at 02:00 UTC every day as `dfo-prod-logs-daily`. It reads `logs_daily.entries`, which is `dfo_logs` from the cut-off on and `backfill_entries` before it. It creates the six tables if they are missing and writes them in one transaction:

- `requests_daily`: requests per day and service, with 4xx and 5xx counts and approximate p50, p95 and p99 latency in milliseconds.
- `routes_daily`: the same per day, service, method and route.
- `errors_daily`: stdout and stderr entries at `WARNING` or above per day, resource type, service or job, the structured `logger` field, and severity. Request logs are excluded, and so is every message.
- `deploys`: each revision that served a request, with the time of its first request and `before_source`. A revision that never passed its startup probe served nothing and has no row.
- `mcp_daily`: the combined MCP server's calls per day, caller kind, client, request and outcome, with an HLL++ sketch of the callers. "MCP calls" below describes it.
- `website_requests_daily`: the website's request lines per day, route, kind, bot verdict and status class, with an HLL++ sketch of the callers. "Website requests" below describes it.

The oldest day in `logs_daily.entries` is partial, because the copy or retention cut entries part way through it, so the oldest whole day is the one after. The day of the run is partial too, so `requests_daily`, `routes_daily`, `errors_daily`, `mcp_daily` and `website_requests_daily` read entries before the current UTC day only. From about 2026-11-22, retention moves `dfo_logs`'s oldest entry past the cut-off, and the view has a gap between the backfill and that entry. The cut-off day and the day of that entry are then partial, and the days between them empty, so the five tables' source reads skip every day from the cut-off day through the day of `dfo_logs`'s oldest entry. An empty `dfo_logs` gives a gap from the cut-off day through yesterday. `logs_daily.sql` reads `dfo_logs` directly to find the gap. Every day the five tables hold is whole. They reload the days from `requests_daily`'s latest loaded day minus one through yesterday, and from the oldest whole day when `requests_daily` is empty. The start never falls before a floor, so a run deletes only days it reloads in full. While `dfo_logs` reaches back to the cut-off, the view has no gap and the floor is the view's oldest whole day. With a gap, the floor is the first whole day after it, the day after `dfo_logs`'s oldest entry. An empty `dfo_logs` with days already loaded gives no start, so the run deletes and loads nothing. `errors_daily` and `website_requests_daily` share the start, so a stretch with no warnings or no website requests cannot widen their window. The `mcp_daily` DELETE and INSERT start at `GREATEST(load_from, gap_end, the day after the cut-off day)`, so a stretch with no MCP calls cannot widen its window either. Without a gap the day of the cut-off is whole, since the backfill holds its entries before the cut-off and `dfo_logs` the rest. With one, `dfo_logs` no longer holds the rest, so the backfill's last whole day is the day before the cut-off day. A missed run heals on the next one as long as the gap is shorter than the bucket's retention. A longer gap loses the days that aged out of the bucket and keeps every day already loaded.

`infra/stacks/telemetry/tests/load_from.test.sh` runs the query's start-day statements over literal sources, through both floors and an empty source, and fails on any start that differs from the one it pins. It also runs the `requests_daily`, `errors_daily`, `mcp_daily` and `website_requests_daily` source reads over entries either side of midnight and fails when the current day loads, and runs a rebuild with and without a gap and fails when a partial day loads, or when `mcp_daily` loads or deletes a day through the cut-off day. Run it by hand after changing those statements.

`deploys` adds each revision it has not seen, timed over the whole of `logs_daily.entries`, today included, and never changes a row. `before_source` is true, as of the run that records the revision, when no other revision of the same service served a request earlier in `logs_daily.entries`. A revision with an earlier sibling was deployed after the source began. One without was serving when the source began, or is the first after a service-wide silence longer than retention, or the first revision of a new service. Its `first_request` is not a known deploy, so deploy markers read only rows where `before_source` is false. Recording it keeps later runs from adding it again once retention trims its early requests, which would time a sparse revision at a request weeks after its deploy. The rule drops the marker of a new service's first deploy. It has one known false marker. An old revision that held 0% of traffic or served only a tag, and later takes traffic, is recorded as a deploy on that later day.

Days are UTC.

### MCP calls

`mcp_daily` counts the lines `harness.combined_mcp` in dfo-ai logs on `dfo-prod-ai`'s stderr, one per tool call, resource read, resource list and initialize. The query reads those lines' fixed fields only. A line from that logger that starts `combined mcp ` in any other shape counts as `request` `unparsed`, with `caller_kind`, `client` and `outcome` `none` and no sketch, so a change of log format in dfo-ai shows as unparsed calls. The server's warnings, which start `combined mcp: `, are not counted. The days through the cut-off day come from `scripts/load-logs-backfill.sh`, as "Backfill" describes, and the scheduled query writes the days after it.

- `caller_kind` is the prefix of the logged caller, the `x-dfo-caller` header: `user`, `key` and `ip` from the website's edge, and `conversation` for the Studio assistant's own calls through the harness. A line with no caller gives `none`, and any other prefix `other`.
- `client` is the client name the MCP client sent, when it matches `^[A-Za-z0-9 ._/-]{1,64}$`, `none` when it sent none, and `other` otherwise.
- `request` is the tool name for a tool call, when it matches `^[A-Za-z0-9_.-]{1,64}$`, and `other` otherwise. It is `resource` for a resource read, `resource_list` for a resource list and `initialize` for an initialize, and `unparsed` for a line the query cannot parse.
- `outcome` is `ok`, a refusal code or the name of the exception the call raised, when it matches `^[A-Za-z0-9_.-]{1,64}$`, and `other` otherwise.
- `calls` counts the lines, and `callers_sketch` is `HLL_COUNT.INIT(caller, 14)` over the logged caller strings, NULL when no line in the row names a caller.

A client chooses its name and the tools it calls, so the patterns keep free text out of the table. No caller string, trace id or URI reaches it. `infra/stacks/telemetry/tests/mcp_daily.test.sh` runs the parse over literal lines in each shape, through the scheduled query and through the loader's script over staged entries either side of the cut-off, and fails on any row that differs from the ones it pins or on any of the script's refusals that does not fire with its code. Run it by hand after changing the parse or either caller.

`mcp_daily` has no row on a day without MCP calls. To check the days after the cut-off day, replace `<cut-off>` with the value in `infra/stacks/telemetry/logs_backfill_cutoff.txt` and list the days on which `requests_daily` holds requests for `dfo-prod-ai`, the service that serves the MCP endpoint, and `mcp_daily` holds no row:

```sh
bq query --project_id=prod-fin-observatory --location=EU --use_legacy_sql=false \
  "SELECT day FROM logs_daily.requests_daily
   WHERE service = 'dfo-prod-ai' AND day > DATE(TIMESTAMP '<cut-off>')
     AND day NOT IN (SELECT day FROM logs_daily.mcp_daily)
   ORDER BY day"
```

A listed day is a gap only when the server took MCP calls that day. If a day with MCP calls is listed, rebuild `logs_daily` once, as "Rebuilding logs_daily from the backfill" describes, to load every MCP line `dfo_logs` still holds. Do it before about 2026-11-22, when retention opens the gap and a rebuild can no longer load the days after the cut-off day through `dfo_logs`' oldest entry. The loader holds the days through the cut-off day.

### Website requests

`website_requests_daily` counts the JSON lines on `dfo-prod-website`'s stdout with `message` `request`, which `src/lib/proxy/requestLog.ts` in dfo-website writes once per visitor request when its response finishes. Other services log lines with that message, so the query keeps the website's only. The query reads `kind`, `status`, `bot`, `path` and `caller`.

- `route` is `normalise_route` of the path, which carries no query string. It is NULL for an unparsed row.
- `kind` is `page`, `api`, `rsc` or `prefetch`. It is `unparsed` for a line whose `kind` is outside those four, whose `status` is not an integer from 100 to 599, or whose `bot` is not a boolean, so a change of the line shows as unparsed requests. An unparsed row has `route`, `bot` and `status_class` NULL and no sketch.
- `bot` is the website's verdict on the request's user agent.
- `status_class` is the response status divided by 100, from 1 to 5.
- `requests` counts the lines, and `callers_sketch` is `HLL_COUNT.INIT(caller, 14)` over the logged `ip:<digest>` caller strings, NULL when no line in the row names a caller.

The website's request lines carry `status` and `bot` from 2026-10-24 00:04 UTC, and the lines before them are unparsed. `website_requests_daily` shares `requests_daily`'s start, so its first run loads only from that start on. If `SELECT MIN(day) FROM logs_daily.website_requests_daily WHERE kind != 'unparsed'` is later than 2026-10-24, rebuild `logs_daily` once, as "Rebuilding logs_daily from the backfill" describes.

A rebuild loads every request line `dfo_logs` still holds. Do it before about 2026-11-22, when retention opens the gap and a rebuild drops the days from 2026-10-23 through `dfo_logs`' oldest entry.

No caller string, host, user agent or path beyond the route reaches the table. `infra/stacks/telemetry/tests/website_requests_daily.test.sh` runs the parse over literal lines in each shape and fails on any row that differs from the ones it pins. Run it by hand after changing the parse.

### Routes

`logs_daily.normalise_route(url)` turns a request URL into a route. It drops the scheme, host, query string, fragment and trailing slashes, collapses everything under `/_next/static/` to `/_next/static/:asset`, and replaces a path segment with `:id` when it starts with a digit, holds an upper-case letter, is a UUID, or holds a digit with no hyphen or dot. API versions such as `v1` stay. The body lives in `sql/normalise_route.sql`.

A share id made only of lower-case letters keeps its value, since nothing in its shape tells it from a word. With 8 characters drawn from 62, about one share id in 1,000 has that shape.

`infra/stacks/telemetry/tests/normalise_route.test.sh` runs the function over `tests/route_sample.tsv`, URL shapes recorded from prod request logs plus hand-written cases, and fails on any route that differs from the one pinned beside it. The query reads only literals and scans no bytes. Run it by hand after changing the function, and add the new shape to the fixture.

## Alerts

Each address in the principals secret's `alerts` object gets its own Cloud Monitoring email channel, named by its label, and every alert in this stack notifies all of them. Six policies watch the data pipeline the dashboard reads:

- `logs_daily scheduled query failed` fires when a run logs an error against the config, or when the Data Transfer Service counts a run as `FAILED`. A run that keeps failing for longer than the bucket's retention loses those days for good.
- `logs_daily scheduled query not succeeding` fires when the config has no succeeded run in the last 26 hours of stored data, including a paused, disabled, or deleted config, which completes no run and so trips neither failure condition. The Data Transfer Service writes zero-valued `SUCCEEDED` points, so the query sums the succeeded runs over the window and also tests for absence. A PromQL condition evaluates it every 5 minutes over stored data, because an absence condition cannot watch a once-a-day success. A config with no success in the 26 hours before the policy exists, such as a newly created config, alerts within minutes, and the incident closes after its first success. It is its own policy with a seven-day auto-close.
- `dfo-prod-website-export Job execution failed` fires when an execution of the website's hourly event export Job fails.
- `dfo-prod-langfuse-export Job execution failed` fires when an execution of the ai stack's hourly Langfuse export Job fails. Langfuse Cloud keeps observations for a limited time, so a long run of failures loses data.
- `dfo-prod-website-export Job not succeeding` and `dfo-prod-langfuse-export Job not succeeding` fire when a Job has no succeeded execution for three hours. They catch what the failure policies cannot see: a paused or failing Scheduler trigger, a renamed or deleted Job, or every run failing. Each is its own policy with a seven-day auto-close, since a shorter timer would close the incident while no execution succeeds.

The four Job policies read Cloud Run's `run.googleapis.com/job/completed_execution_count`, with `result="failed"` or `result="succeeded"`, filtered by job name. The Jobs belong to the website and ai stacks, and this stack names them by their fixed names. A Job not yet created has no series, so its policies stay quiet, and the absence policy starts watching after the Job's first succeeded execution, since Cloud Monitoring needs one measurement before a series can go absent.

## Search Console

The dataset `searchconsole` takes Search Console's bulk data export. `search-console-data-export@system.gserviceaccount.com` gets `WRITER` on it and `roles/bigquery.jobUser` on the project. The export has no backfill, so the data starts from the day it is turned on. If the bulk-export setup refuses the dataset-level grant, give that account project-level `roles/bigquery.dataEditor`, as Search Console's setup docs ask.

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

## Reporting views

`dfo_reporting` holds one view per dashboard source, each a template under `infra/stacks/telemetry/sql/reporting` that `reporting_views.tf` renders. The views hold counts, sums, durations and route or page paths, and no user id, IP, raw conversation id or free text. Each view is an authorised view on every dataset it reads, through a `google_bigquery_dataset_access` with a `view` block, so readers of `dfo_reporting` query the views without access to the sources.

| View                     | Grain                                                    | Columns                                                                                                                                                                                                      |
| ------------------------ | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `service_requests_daily` | UTC day, service                                         | `day`, `service`, `requests`, `status_4xx`, `status_5xx`, `latency_p50_ms`, `latency_p95_ms`, `latency_p99_ms`                                                                                               |
| `service_routes_daily`   | UTC day, service, method, route                          | `day`, `service`, `method`, `route`, then as `service_requests_daily`                                                                                                                                        |
| `service_errors_daily`   | UTC day, resource type, service or job, logger, severity | `day`, `resource_type`, `service`, `logger`, `severity`, `entries`                                                                                                                                           |
| `deploys`                | revision                                                 | `service`, `revision`, `deployed_at`                                                                                                                                                                         |
| `mcp_daily`              | UTC day, caller kind, client, request, outcome           | `day`, `caller_kind`, `client`, `request`, `outcome`, `calls`, `callers_sketch`                                                                                                                              |
| `website_requests_daily` | UTC day, route, kind, bot, status class                  | `day`, `route`, `kind`, `bot`, `status_class`, `requests`, `callers_sketch`                                                                                                                                  |
| `product_events_daily`   | UTC day, event name, page, signed-in state               | `day`, `event`, `page`, `signed_in`, `events`, `visitors_sketch`, `users_sketch`                                                                                                                             |
| `account_returns_daily`  | UTC day of a signed-in event                             | `day`, `active_sketch`, `returning_sketch`                                                                                                                                                                   |
| `accounts_daily`         | UTC day of account creation, organisation                | `day`, `organisation`, `accounts`                                                                                                                                                                            |
| `ai_turns`               | turn                                                     | `day`, `started_at`, `session_sketch`, `latency_seconds`, `time_to_first_token_seconds`, `generations`, `tool_calls`, `input_tokens`, `output_tokens`, `cost_usd`, `errored`                                 |
| `ai_observations_daily`  | UTC day, type, name, model, trace name, level            | `day`, `type`, `name`, `model`, `observations`, `errors`, `latency_p50_seconds`, `latency_p95_seconds`, `input_tokens`, `output_tokens`, `cost_usd`, `trace_name`, `level`, `total_tokens`, `latency_sketch` |
| `ga4_daily`              | day in the property's time zone                          | `day`, `active_users`, `sessions`, `page_views`                                                                                                                                                              |
| `ga4_pages_daily`        | day in the property's time zone, page path               | `day`, `page_path`, `page_views`, `sessions`                                                                                                                                                                 |
| `search_console_daily`   | Pacific Time day                                         | `day`, `clicks`, `impressions`, `sum_position`                                                                                                                                                               |
| `search_console_pages`   | Pacific Time day, page URL                               | `day`, `url`, `clicks`, `impressions`, `sum_position`                                                                                                                                                        |
| `model_spend_daily`      | UTC day, caller, service, SKU, currency                  | `day`, `caller`, `service`, `sku`, `cost`, `credits`, `net_cost`, `currency`                                                                                                                                 |

The `_sketch` columns other than `latency_sketch` are HLL++ sketches (`HLL_COUNT.INIT(x, 14)`), so distinct visitors, users, accounts, sessions, MCP callers and website callers over any set of rows come from `HLL_COUNT.MERGE` over those rows, and no id or hash of one reaches `dfo_reporting`. The other figures sum across rows, except quantiles and active users, which hold for their own row only. GA4 sessions sum across days but not across pages, and a session that crosses midnight counts on both days, so a sum over several days runs slightly high.

The service views, `website_requests_daily` and `mcp_daily` read `logs_daily`, and `deploys` keeps only the revisions deployed while the logs source ran (`before_source` false), which are the deploy markers.

`product_events_daily` reads `website_export.event`. Its `page` is the path through `normalise_route`, so ids in paths such as `/studio/<id>` read `:id`. `dfo_reporting` holds its own `normalise_route`, built from the same `sql/normalise_route.sql` as the one in `logs_daily`, since readers can run routines in `dfo_reporting` and have no access to `logs_daily`. `visitors_sketch` holds the export's `visitor_hash` values and `users_sketch` its `user_hash` values, which only signed-in events carry.

`account_returns_daily` reads `website_export.event` and keeps the signed-in events, the ones with a `user_hash`, so a day with none has no row. `active_sketch` holds that day's `user_hash` values. `returning_sketch` holds those of the accounts whose first signed-in event in the table falls on an earlier day, and is NULL when the day has none. `HLL_COUNT.MERGE` over a window's `active_sketch` counts the accounts active in it, and over its `returning_sketch` the accounts active on a day after their first active day, each once however many days it returned on. An account's first active day is its first in the days the export holds, whatever the window. Rotating the export's HMAC key gives every account a new hash, so from that day every account counts as new and returns count afresh.

`accounts_daily` reads `website_export.account_daily`, which the website export writes from a Postgres view and replaces whole on every run. It holds every UTC day from the first account through the day before the run. `organisation` is the lower-cased email domain when that domain holds at least 3 accounts in total, `Personal email` for a webmail domain, and `Other organisations` otherwise, so no address or user id leaves Postgres. A day with no new accounts has one row with `organisation` NULL and `accounts` 0, so the latest day in the view is always the last complete day. The view has its own source group, `accounts`, because its table exists only after the export run that writes it.

`ai_turns` has one row per Langfuse trace named `turn`, from `langfuse_export.observations`. `started_at`, `day` and `latency_seconds` are those of its span named `turn`, and a trace whose turn span was not exported runs from its first observation's start to its last one's end. `time_to_first_token_seconds` is the turn span's when it has one, and otherwise runs from `started_at` to the first token of the turn's first generation. `generations` counts `GENERATION` observations and `tool_calls` `TOOL` ones. `errored` is true when any observation in the trace is at `ERROR`. `ai_observations_daily` covers every trace, and `errors` counts its rows' observations at `ERROR`. Its `latency_sketch` is a KLL sketch (`KLL_QUANTILES.INIT_FLOAT64(latency_seconds, 1000)`) of the row's latencies, NULL when none has one. `KLL_QUANTILES.MERGE_POINT_FLOAT64(latency_sketch, 0.95)` over several rows gives the quantile of their pooled observations, which `latency_p50_seconds` and `latency_p95_seconds` cannot.

The GA4 and Search Console views join `web_history` to the exports. Each view reads its export's first day from the export itself and takes history rows only for earlier days, so no day is counted twice. GA4 export days count active users (`is_active_user`), sessions (`ga_session_id` per user) and page views (`page_view` and `screen_view` events) exactly, the history days are the Data API's figures, and `page_path` is `page_location` without host, query string or fragment. `ga4_daily` holds each day's active users and sessions, which do not sum from `ga4_pages_daily`. The Search Console views keep web search only. `search_console_pages` strips the query string and fragment from the export's URLs and sums the rows that then match, as the history loader does.

`model_spend_daily` reads the standard usage cost export, `billing_export.gcp_billing_export_v1_*`, and keeps only the projects in `spend_callers` (`reporting.auto.tfvars`), labelled with their caller, since the billing account also bills projects outside DFO. Add each Gemini caller's AI Studio key project there. Cloud Billing keeps adding cost to a day for about a day after it ends, so the view keeps only days before yesterday (UTC), and every day it holds is whole. `credits` is negative and `net_cost` is `cost` plus `credits`.

`tests/reporting_*.test.sh` in `infra/stacks/telemetry` run each view over literal source rows and fail on any row that differs from the ones they pin. Run them by hand after changing a view.

### Switching a source on

A view cannot name a table that does not exist, so `reporting_sources` in `reporting.auto.tfvars` lists the source groups whose tables exist, and only their views and authorised-view entries are created. Add a group once the tables below exist, and apply.

| Group              | Views                                           | Tables that must exist                                                                                                                                                                            |
| ------------------ | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `logs`             | the three service views and `deploys`           | `logs_daily.requests_daily`, `routes_daily`, `errors_daily` and `deploys`, from the first `dfo-prod-logs-daily` run                                                                               |
| `mcp`              | `mcp_daily`                                     | `logs_daily.mcp_daily`, from the first `dfo-prod-logs-daily` run                                                                                                                                  |
| `website_requests` | `website_requests_daily`                        | `logs_daily.website_requests_daily`, from the first `dfo-prod-logs-daily` run                                                                                                                     |
| `website`          | `product_events_daily`, `account_returns_daily` | `website_export.event`, from the website export Job's first run                                                                                                                                   |
| `accounts`         | `accounts_daily`                                | `website_export.account_daily`, from the first website export Job run that writes it                                                                                                              |
| `langfuse`         | `ai_turns`, `ai_observations_daily`             | `langfuse_export.observations`, from the Langfuse export Job's first run                                                                                                                          |
| `ga4`              | `ga4_daily`, `ga4_pages_daily`                  | an `analytics_<property id>.events_YYYYMMDD` table, and `web_history.ga4_daily` and `ga4_pages_daily` from `scripts/load-ga4-history.sh`                                                          |
| `search_console`   | `search_console_daily`, `search_console_pages`  | `searchconsole.searchdata_site_impression` and `searchdata_url_impression`, and `web_history.search_console_daily` and `search_console_pages_daily` from `scripts/load-search-console-history.sh` |
| `billing`          | `model_spend_daily`                             | a `billing_export.gcp_billing_export_v1_*` table                                                                                                                                                  |

`bq ls prod-fin-observatory:<dataset>` lists a dataset's tables.

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
- `dfo-prod-logs-daily` first runs at the next 02:00 UTC. To run it sooner, start a manual run from the BigQuery console's Scheduled queries page.
