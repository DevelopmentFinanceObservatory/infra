# telemetry (prod)

Prod's telemetry plumbing in BigQuery, which the team dashboard reads through the `dfo_reporting` dataset. The stack routes Cloud Run logs into a Log Analytics bucket, holds a one-off copy of the Cloud Run logs from before that route started, aggregates both daily into `logs_daily`, holds the dataset Search Console exports into, builds the reporting views in `dfo_reporting`, grants readers access to it, and holds the datasets, accounts and scheduled Jobs of the analytics repository. The `.tf` files, `ga4_user_ranges.yaml` and the `sql` directory are symlinks to `infra/stacks/telemetry`. This directory holds prod's backend, tfvars, and lock file. The stack exists in prod only.

Every dataset is in the EU multi-region. Every dataset-level grant is a `google_bigquery_dataset_access`, and no dataset declares `access` blocks. Authoritative blocks, or `google_bigquery_dataset_iam_*` resources, would remove the other entries on the next apply, including the authorised-view entries the reporting views need on their sources.

## Logs

The sink `dfo-prod-telemetry` copies every `cloud_run_revision` and `cloud_run_job` entry from the `run.googleapis.com/requests`, `stdout` and `stderr` logs into the bucket `dfo-prod-telemetry` in `eu`, which keeps them for `log_retention_days` (365, set in `env.auto.tfvars`). The `_Default` bucket also receives the same entries. The filter names resource types and log ids, so a new or renamed service is routed with no change here. It leaves out the website's usage-event lines (`jsonPayload.message="event"` on `dfo-prod-website`'s stdout). They repeat the Postgres `event` table, which is the events source the website export copies, and their props carry the first 500 characters of each search query.

The bucket's linked dataset `dfo_logs` exposes the entries to BigQuery as the view `dfo_logs._AllLogs`. The entries hold request IPs and user agents. BigQuery roles decide who can read them. The `dfo-prod-logs-daily` service account reads `dfo_logs` through its dataset grant, and so do `dfo-prod-analytics-ci`, `dfo-prod-analytics-runner` and the analytics developers ("Analytics repo"). Any principal with a project-level BigQuery data role reads it too. Those are the applier (`roles/bigquery.dataOwner`), `dfo-prod-dc-ing-pst-sa` (`roles/bigquery.dataEditor`), and the project owners. If the linked dataset carries BigQuery's default `projectWriters` and `projectReaders` entries, as datasets Terraform creates here do, the project's editors and viewers read it as well. Those are the default compute service account and the Google APIs service agent (`roles/editor`) and `dfo-infra-planner` (`roles/viewer`).

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

The scheduled query `dfo-prod-logs-daily` runs `sql/logs_daily.sql` at 02:00 UTC every day as `dfo-prod-logs-daily`, until `analytics_dbt_schedule_enabled` disables it and the analytics dbt Job takes over ("Analytics jobs"). It reads `logs_daily.entries`, which is `dfo_logs` from the cut-off on and `backfill_entries` before it. It creates the six tables if they are missing and writes them in one transaction:

- `requests_daily`: requests per day and service, with 4xx and 5xx counts and approximate p50, p95 and p99 latency in milliseconds.
- `routes_daily`: the same per day, service, method and route.
- `errors_daily`: stdout and stderr entries at `WARNING` or above per day, resource type, service or job, the structured `logger` field, and severity. Request logs are excluded, and so is every message.
- `deploys`: each revision that served a request, with the time of its first request and `before_source`. A revision that never passed its startup probe served nothing and has no row.
- `mcp_daily`: the combined MCP server's calls per day, caller kind, client, request and outcome, with an HLL++ sketch of the callers. "MCP calls" below describes it.
- `website_requests_daily`: the website's request lines per day, route, kind, bot verdict and status class, with an HLL++ sketch of the callers. "Website requests" below describes it.

The oldest day in `logs_daily.entries` is partial, because the copy or retention cut entries part way through it, so the oldest whole day is the one after. The day of the run is partial too, so `requests_daily`, `routes_daily`, `errors_daily`, `mcp_daily` and `website_requests_daily` read entries before the current UTC day only. From about 2027-10-23, retention moves `dfo_logs`'s oldest entry past the cut-off, and the view has a gap between the backfill and that entry. The cut-off day and the day of that entry are then partial, and the days between them empty, so the five tables' source reads skip every day from the cut-off day through the day of `dfo_logs`'s oldest entry. An empty `dfo_logs` gives a gap from the cut-off day through yesterday. `logs_daily.sql` reads `dfo_logs` directly to find the gap. Every day the five tables hold is whole. They reload the days from `requests_daily`'s latest loaded day minus one through yesterday, and from the oldest whole day when `requests_daily` is empty. The start never falls before a floor, so a run deletes only days it reloads in full. While `dfo_logs` reaches back to the cut-off, the view has no gap and the floor is the view's oldest whole day. With a gap, the floor is the first whole day after it, the day after `dfo_logs`'s oldest entry. An empty `dfo_logs` with days already loaded gives no start, so the run deletes and loads nothing. `errors_daily` and `website_requests_daily` share the start, so a stretch with no warnings or no website requests cannot widen their window. The `mcp_daily` DELETE and INSERT start at `GREATEST(load_from, gap_end, the day after the cut-off day)`, so a stretch with no MCP calls cannot widen its window either. Without a gap the day of the cut-off is whole, since the backfill holds its entries before the cut-off and `dfo_logs` the rest. With one, `dfo_logs` no longer holds the rest, so the backfill's last whole day is the day before the cut-off day. A missed run heals on the next one as long as the gap is shorter than the bucket's retention. A longer gap loses the days that aged out of the bucket and keeps every day already loaded.

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

A listed day is a gap only when the server took MCP calls that day. If a day with MCP calls is listed, rebuild `logs_daily` once, as "Rebuilding logs_daily from the backfill" describes, to load every MCP line `dfo_logs` still holds. Do it before about 2027-10-23, when retention opens the gap and a rebuild can no longer load the days after the cut-off day through `dfo_logs`' oldest entry. The loader holds the days through the cut-off day.

### Website requests

`website_requests_daily` counts the JSON lines on `dfo-prod-website`'s stdout with `message` `request`, which `src/lib/proxy/requestLog.ts` in dfo-website writes once per visitor request when its response finishes. Other services log lines with that message, so the query keeps the website's only. The query reads `kind`, `status`, `bot`, `path` and `caller`.

- `route` is `normalise_route` of the path, which carries no query string. It is NULL for an unparsed row.
- `kind` is `page`, `api`, `rsc` or `prefetch`. It is `unparsed` for a line whose `kind` is outside those four, whose `status` is not an integer from 100 to 599, or whose `bot` is not a boolean, so a change of the line shows as unparsed requests. An unparsed row has `route`, `bot` and `status_class` NULL and no sketch.
- `bot` is the website's verdict on the request's user agent.
- `status_class` is the response status divided by 100, from 1 to 5.
- `requests` counts the lines, and `callers_sketch` is `HLL_COUNT.INIT(caller, 14)` over the logged `ip:<digest>` caller strings, NULL when no line in the row names a caller.

The website's request lines carry `status` and `bot` from 2026-10-24 00:04 UTC, and the lines before them are unparsed. `website_requests_daily` shares `requests_daily`'s start, so its first run loads only from that start on. If `SELECT MIN(day) FROM logs_daily.website_requests_daily WHERE kind != 'unparsed'` is later than 2026-10-24, rebuild `logs_daily` once, as "Rebuilding logs_daily from the backfill" describes.

A rebuild loads every request line `dfo_logs` still holds. Do it before about 2027-10-23, when retention opens the gap and a rebuild drops the days from 2026-10-23 through `dfo_logs`' oldest entry.

No caller string, host, user agent or path beyond the route reaches the table. `infra/stacks/telemetry/tests/website_requests_daily.test.sh` runs the parse over literal lines in each shape and fails on any row that differs from the ones it pins. Run it by hand after changing the parse.

### Routes

`logs_daily.normalise_route(url)` turns a request URL into a route. It drops the scheme, host, query string, fragment and trailing slashes, collapses everything under `/_next/static/` to `/_next/static/:asset`, and replaces a path segment with `:id` when it starts with a digit, holds an upper-case letter, is a UUID, or holds a digit with no hyphen or dot. API versions such as `v1` stay. The body lives in `sql/normalise_route.sql`.

A share id made only of lower-case letters keeps its value, since nothing in its shape tells it from a word. With 8 characters drawn from 62, about one share id in 1,000 has that shape.

`infra/stacks/telemetry/tests/normalise_route.test.sh` runs the function over `tests/route_sample.tsv`, URL shapes recorded from prod request logs plus hand-written cases, and fails on any route that differs from the one pinned beside it. The query reads only literals and scans no bytes. Run it by hand after changing the function, and add the new shape to the fixture.

## Alerts

Each address in the principals secret's `alerts` object gets its own Cloud Monitoring email channel, named by its label, and every alert in this stack notifies all of them. Seven policies watch the data pipeline the dashboard reads:

- `logs_daily scheduled query failed` fires when a run logs an error against the config, or when the Data Transfer Service counts a run as `FAILED`. A run that keeps failing for longer than the bucket's retention loses those days for good.
- `logs_daily scheduled query not succeeding`, which exists while `analytics_dbt_schedule_enabled` is false, fires when the config has no succeeded run in the last 26 hours of stored data, including a paused, disabled, or deleted config, which completes no run and so trips neither failure condition. The Data Transfer Service writes zero-valued `SUCCEEDED` points, so the query sums the succeeded runs over the window and also tests for absence. A PromQL condition evaluates it every 5 minutes over stored data, because an absence condition cannot watch a once-a-day success. A config with no success in the 26 hours before the policy exists, such as a newly created config, alerts within minutes, and the incident closes after its first success. It is its own policy with a seven-day auto-close.
- `dfo-prod-website-export Job execution failed` fires when an execution of the website's hourly event export Job fails.
- `dfo-prod-langfuse-export Job execution failed` fires when an execution of the ai stack's hourly Langfuse export Job fails. Langfuse Cloud keeps observations for a limited time, so a long run of failures loses data.
- `dfo-prod-website-export Job not succeeding` and `dfo-prod-langfuse-export Job not succeeding` fire when a Job has no succeeded execution in the last three hours of stored data. They catch what the failure policies cannot see: a paused or failing Scheduler trigger, a renamed or deleted Job, or every run failing. Each is its own policy with a seven-day auto-close, since a shorter timer would close the incident while no execution succeeds.
- `dfo-prod-ga4-user-ranges workflow execution failed` fires when an execution of the daily GA4 range pull fails, scheduled or run by hand. It reads Workflows' `workflows.googleapis.com/finished_execution_count` with `status="FAILED"`. A paused Scheduler trigger starts no execution and trips nothing, and `fetched_at` in `ga4_user_ranges` then stops moving.

With `analytics_jobs_enabled` on, `analytics_jobs.tf` adds twenty more with every probe, topics pass and the observation specs Job switched on, and three once `analytics_dbt_schedule_enabled` is on too:

- `dfo-prod-analytics-edge Job not succeeding` fires when the edge extract has no succeeded execution for three hours, and `dfo-prod-analytics-dbt Job not succeeding` and `dfo-prod-analytics-freshness Job not succeeding` do the same for the dbt build and the freshness check once `analytics_dbt_schedule_enabled` gives them triggers. A single failed dbt or edge run raises nothing, since the next run retries it: the dbt build replaces the last three days, and the extract reads each object for three days after it lands. A failed freshness run alerts through its own failure policy below. Each has a seven-day auto-close.
- `dfo-prod-analytics-grade Job execution failed` fires when an execution of the daily grader fails, since its retry is a day away.
- `dfo-prod-analytics-grade Job not succeeding` fires when the grader has no succeeded execution in the last 26 hours, a PromQL condition built as the logs_daily one is. It alerts within minutes of the flag going on and closes after the Job's first success.
- `dfo-prod-analytics-topics-variables Job execution failed`, `dfo-prod-analytics-topics-turns Job execution failed` and `dfo-prod-analytics-topics-specs Job execution failed` fire when an execution of a topics pass fails. The `turns` retry is a day away and the other two a week.
- `dfo-prod-analytics-topics-variables Job not succeeding` and `dfo-prod-analytics-topics-specs Job not succeeding` fire when the weekly pass has no succeeded execution in 192 hours, evaluated hourly. `dfo-prod-analytics-topics-turns Job not succeeding` fires when the daily pass has none in 26 hours, evaluated every 300 s as the grade policy is. Each is a PromQL condition built as the probes' are, exists only once its entry in `analytics_probes_enabled` is true, and closes after the pass's next success.
- `dfo-prod-analytics-call-specs Job not succeeding` fires when the hourly observation specs extract has no succeeded execution for five hours. The Job skips 04:35, 05:35 and 06:35, so two successes can be four hours apart, and the fifth hour covers one failed run beside the gap. A single failed run raises nothing, since the next run retries it. It exists only once the `call-specs` entry in `analytics_probes_enabled` is true, and it reads the five hours before it, so a switch-on more than five hours after the canary opens an incident that closes at the first scheduled success.
- `dfo-prod-analytics-call-specs lost observation rows` fires when the Job logs a line with `event="observation_spec_lost"`, one for each observation row that failed its last attempt, with the fields `observation_id` and `last_status`. The run itself succeeds, so no Job policy sees it. The log-based metric `dfo-prod-analytics-call-specs-lost` counts those lines on the Job, and the policy exists whatever the switch says.
- `dfo-prod-analytics-edge lost rejected, unreadable or deleted objects` fires when the edge extract's `run summary:` line, its last stdout line, carries `rejected=`, `unreadable=` or `deleted=` above zero. The log-based metric `dfo-prod-analytics-edge-objects-lost` counts those lines with the filter `textPayload=~"^run summary: .* (rejected|unreadable|deleted)=[1-9]"` on the edge Job, as the analytics repository's README documents. Each such object's deliveries are lost: a rejected one was named in `EDGE_REJECT_OBJECTS`, an unreadable one could not be decompressed or exceeded 256 MiB, and a deleted one left the bucket between the listing and the read. The run itself succeeds, so no Job policy sees it.
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

GA4's active users do not sum across days, since a visitor who returns counts on every day they visit. On 2026-10-24 the Data API gave 1,113 active users for 2026-10-05 to 2026-10-23, against 1,279 summed over the days. Two sources give unique users over a period, and both count only visitors who accepted analytics storage, as every GA4 user figure does (see "Reporting views").

- `ga4_daily`'s `users_sketch` is an HLL++ sketch of each export day's active users, so `HLL_COUNT.MERGE` over any window of export days gives its unique users, within HLL++ error. It covers the days from the GA4 export's first day, 2026-10-23, and is NULL on the history days before it, which the Data API reported only as counts.
- `ga4_user_ranges` holds the Data API's active, total and new users over fixed ranges, each user counted once per range. It covers every day GA4 holds, from 2026-10-14, but only the ranges asked for in advance. Each range ends at the data end, the earlier of yesterday and GA4's last day with data, since GA4 may not have processed yesterday when the run starts. The ranges are: since the floor, 2026-10-05, through the data end; the last 7 and the last 28 days ending at the data end; each ISO week, Monday to Sunday, and each calendar month from the floor's. The current week and month end at the data end, and one that would start after it, such as a Monday's week when GA4 holds only up to Sunday, is not asked for until a later run. No range is cut at the floor, so `last_28` is always 28 days and the first month starts on 2026-10-01. A range that ends before GA4's first day with data, such as the week of 2026-10-05, is not asked for either, so GA4 has a row for every range asked for. The request sets `keepEmptyRows`, so a range with no users returns a row of zeros instead of no row.

The workflow `dfo-prod-ga4-user-ranges` (`ga4_user_ranges.tf`) fills `web_history.ga4_user_ranges`. Cloud Scheduler starts it at 06:00 UTC every day as `dfo-prod-ga4-ranges-sch`, which holds `roles/workflows.invoker` on the project and nothing else. The workflow runs as `dfo-prod-web-history`, the history loaders' service account, which already has GA4 Viewer, `WRITER` on `web_history` and `roles/bigquery.jobUser`. A run reads the property's time zone (`Etc/GMT`) and its first and last days with data from one Data API report, lists the ranges with `sql/ga4_user_ranges_requests.sql`, asks `runReport` for them four at a time, the API's limit, and replaces the whole table in one `MERGE` built on `sql/ga4_user_ranges_rows.sql`. GA4 keeps revising a day for 2 to 3 days, and each run rereads every range, so the revisions land on later runs. An API error fails the run before the `MERGE`, and a range with no row or more than one fails the `MERGE`, so a failed run leaves the table as it was, and the alert above fires.

To run it by hand, as a principal with `roles/workflows.invoker` on the project, such as a project owner:

```sh
gcloud workflows run dfo-prod-ga4-user-ranges --project=prod-fin-observatory --location=europe-west1
```

It prints the execution's result, the number of requests and the `MERGE` job's id, or its error. `infra/stacks/telemetry/tests/ga4_user_ranges.test.sh` runs both queries over fixed dates and literal Data API replies. Run it by hand after changing either one.

## Reporting views

`dfo_reporting` holds one view per dashboard source, each a template under `infra/stacks/telemetry/sql/reporting` that `reporting_views.tf` renders. The views hold counts, sums, durations and route or page paths, and no user id, IP, raw conversation id or free text. Each view is an authorised view on every dataset it reads, through a `google_bigquery_dataset_access` with a `view` block, so readers of `dfo_reporting` query the views without access to the sources.

| View                       | Grain                                                    | Columns                                                                                                                                                                                                                             |
| -------------------------- | -------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `service_requests_daily`   | UTC day, service                                         | `day`, `service`, `requests`, `status_4xx`, `status_5xx`, `latency_p50_ms`, `latency_p95_ms`, `latency_p99_ms`                                                                                                                      |
| `service_routes_daily`     | UTC day, service, method, route                          | `day`, `service`, `method`, `route`, then as `service_requests_daily`                                                                                                                                                               |
| `service_errors_daily`     | UTC day, resource type, service or job, logger, severity | `day`, `resource_type`, `service`, `logger`, `severity`, `entries`                                                                                                                                                                  |
| `deploys`                  | revision                                                 | `service`, `revision`, `deployed_at`                                                                                                                                                                                                |
| `mcp_daily`                | UTC day, caller kind, client, request, outcome           | `day`, `caller_kind`, `client`, `request`, `outcome`, `calls`, `callers_sketch`                                                                                                                                                     |
| `website_requests_daily`   | UTC day, route, kind, bot, status class                  | `day`, `route`, `kind`, `bot`, `status_class`, `requests`, `callers_sketch`                                                                                                                                                         |
| `website_page_views_daily` | UTC day                                                  | `day`, `page_views`, `bot_page_views`                                                                                                                                                                                               |
| `product_events_daily`     | UTC day, event name, page, signed-in state               | `day`, `event`, `page`, `signed_in`, `events`, `visitors_sketch`, `users_sketch`                                                                                                                                                    |
| `account_returns_daily`    | UTC day of a signed-in event                             | `day`, `active_sketch`, `returning_sketch`                                                                                                                                                                                          |
| `accounts_daily`           | UTC day of account creation, organisation                | `day`, `organisation`, `accounts`                                                                                                                                                                                                   |
| `ai_turns`                 | turn                                                     | `day`, `started_at`, `session_sketch`, `latency_seconds`, `time_to_first_token_seconds`, `generations`, `tool_calls`, `input_tokens`, `output_tokens`, `cost_usd`, `errored`, `cached_input_tokens`                                 |
| `ai_observations_daily`    | UTC day, type, name, model, trace name, level            | `day`, `type`, `name`, `model`, `observations`, `errors`, `latency_p50_seconds`, `latency_p95_seconds`, `input_tokens`, `output_tokens`, `cost_usd`, `trace_name`, `level`, `total_tokens`, `latency_sketch`, `cached_input_tokens` |
| `ga4_daily`                | day in the property's time zone                          | `day`, `active_users`, `sessions`, `page_views`, `declined_page_views`, `users_sketch`                                                                                                                                              |
| `ga4_pages_daily`          | day in the property's time zone, page path               | `day`, `page_path`, `page_views`, `sessions`, `declined_page_views`                                                                                                                                                                 |
| `ga4_user_ranges`          | range kind, range                                        | `range_kind`, `range_start`, `range_end`, `active_users`, `total_users`, `new_users`, `fetched_at`                                                                                                                                  |
| `search_console_daily`     | Pacific Time day                                         | `day`, `clicks`, `impressions`, `sum_position`                                                                                                                                                                                      |
| `search_console_pages`     | Pacific Time day, page URL                               | `day`, `url`, `clicks`, `impressions`, `sum_position`                                                                                                                                                                               |
| `cloudflare_daily`         | UTC day                                                  | `day`, `page_loads`, `verified_bot_page_loads`                                                                                                                                                                                      |
| `cloudflare_pages_daily`   | UTC day, path                                            | `day`, `path`, `page_loads`, `verified_bot_page_loads`                                                                                                                                                                              |
| `model_spend_daily`        | UTC day, caller, service, SKU, currency                  | `day`, `caller`, `service`, `sku`, `cost`, `credits`, `net_cost`, `currency`                                                                                                                                                        |

The `_sketch` columns other than `latency_sketch` are HLL++ sketches (`HLL_COUNT.INIT(x, 14)`), so distinct visitors, users, accounts, sessions, MCP callers and website callers over any set of rows come from `HLL_COUNT.MERGE` over those rows, and no id or hash of one reaches `dfo_reporting`. `ga4_daily`'s `users_sketch` holds the active users' `user_pseudo_id` values on export days and is NULL on history days, so a merge over a window reaching before the export counts only its export days, and `ga4_user_ranges` covers those windows (see "GA4 unique users"). The other figures sum across rows, except quantiles and active users, which hold for their own row only. GA4 sessions sum across days but not across pages, and a session that crosses midnight counts on both days, so a sum over several days runs slightly high.

The service views, `website_requests_daily`, `website_page_views_daily` and `mcp_daily` read `logs_daily`, and `deploys` keeps only the revisions deployed while the logs source ran (`before_source` false), which are the deploy markers.

`analytics_dbt_schedule_enabled` disables the `dfo-prod-logs-daily` scheduled query, so the `logs_daily` tables stop growing under it. Under the same switch those seven views read the analytics dbt build's tables in `analytics` instead, and their authorised-view entries move from `logs_daily` and `web_history` to `analytics`. Each view reads the table of the same name: `requests_daily`, `routes_daily`, `errors_daily`, `mcp_daily`, `website_requests_daily`, `website_page_views_daily` and `deploys`. Those tables carry the columns and types the views select. `website_page_views_daily` then reads `analytics.website_page_views_daily`, which the build makes with the rule below, through `sql/reporting/website_page_views_daily_analytics.sql`. Step 6 of "Switching the Jobs on" checks that the two sources agree before the switch.

`website_page_views_daily` counts the website's page views per day: requests of kind `page` answered 2xx, from visitors the website did not judge to be bots in `page_views` and from bots in `bot_page_views`. From the request log's first parsed day, the first day on which `logs_daily.website_requests_daily` holds a row other than `unparsed`, it sums those rows. Before that day it reads `web_history.website_page_history` (see "Website page views before the request log"), which counts the public hosts only, while the request log counts every host the service answers. The seam is read from the request log inside the view, so no day is counted twice, and a day such as 2026-10-23, which holds only unparsed lines, keeps its history row. A later day holding only unparsed lines has no row. The view has no callers sketch, since the history cannot rebuild the website's caller digest, so distinct networks come from `website_requests_daily` and start on its first parsed day.

`product_events_daily` reads `website_export.event`. Its `page` is the path through `normalise_route`, so ids in paths such as `/studio/<id>` read `:id`. `dfo_reporting` holds its own `normalise_route`, built from the same `sql/normalise_route.sql` as the one in `logs_daily`, since readers can run routines in `dfo_reporting` and have no access to `logs_daily`. `visitors_sketch` holds the export's `visitor_hash` values and `users_sketch` its `user_hash` values, which only signed-in events carry.

`account_returns_daily` reads `website_export.event` and keeps the signed-in events, the ones with a `user_hash`, so a day with none has no row. `active_sketch` holds that day's `user_hash` values. `returning_sketch` holds those of the accounts whose first signed-in event in the table falls on an earlier day, and is NULL when the day has none. `HLL_COUNT.MERGE` over a window's `active_sketch` counts the accounts active in it, and over its `returning_sketch` the accounts active on a day after their first active day, each once however many days it returned on. An account's first active day is its first in the days the export holds, whatever the window. Rotating the export's HMAC key gives every account a new hash, so from that day every account counts as new and returns count afresh.

`accounts_daily` reads `website_export.account_daily`, which the website export writes from a Postgres view and replaces whole on every run. It holds every UTC day from the first account through the day before the run. `organisation` is the lower-cased email domain when that domain holds at least 3 accounts in total, `Personal email` for a webmail domain, and `Other organisations` otherwise, so no address or user id leaves Postgres. A day with no new accounts has one row with `organisation` NULL and `accounts` 0, so the latest day in the view is always the last complete day. The view has its own source group, `accounts`, because its table exists only after the export run that writes it.

`ai_turns` has one row per Langfuse trace named `turn`, from `langfuse_export.observations`. `started_at`, `day` and `latency_seconds` are those of its span named `turn`, and a trace whose turn span was not exported runs from its first observation's start to its last one's end. `time_to_first_token_seconds` is the turn span's when it has one, and otherwise runs from `started_at` to the first token of the turn's first generation. `generations` counts `GENERATION` observations and `tool_calls` `TOOL` ones. `errored` is true when any observation in the trace is at `ERROR`. `cached_input_tokens` is the part of `input_tokens` served from the model's cache, summed per turn on `ai_turns` and per row on `ai_observations_daily`, and NULL when no observation in the turn or row records one. `ai_observations_daily` covers every trace, and `errors` counts its rows' observations at `ERROR`. Its `latency_sketch` is a KLL sketch (`KLL_QUANTILES.INIT_FLOAT64(latency_seconds, 1000)`) of the row's latencies, NULL when none has one. `KLL_QUANTILES.MERGE_POINT_FLOAT64(latency_sketch, 0.95)` over several rows gives the quantile of their pooled observations, which `latency_p50_seconds` and `latency_p95_seconds` cannot.

The GA4 and Search Console views join `web_history` to the exports. Each view reads its export's first day from the export itself and takes history rows only for earlier days, so no day is counted twice. GA4 export days count active users (`is_active_user`), sessions (`ga_session_id` per user) and page views (`page_view` and `screen_view` events) exactly, the history days are the Data API's figures, and `page_path` is `page_location` without host, query string or fragment. `ga4_daily` holds each day's active users and sessions, which do not sum from `ga4_pages_daily`. `ga4_user_ranges` reads `web_history.ga4_user_ranges` and passes its rows through.

The website runs Google Consent Mode v2 with analytics storage denied until a visitor accepts, so GA4 still receives cookieless events from visitors who decline. The export keeps them, with `privacy_info.analytics_storage` `No` and no `user_pseudo_id`, and the Data API leaves them out. Those events carry no user or session, so `active_users` and `sessions` count accepted visitors only on every day. `page_views` counts every visitor's page views on export days and accepted visitors' on history days, so the series steps up on the export's first day. `declined_page_views` is the declined part on export days and NULL on history days, since the Data API cannot report it. Accepted page views are `page_views - IFNULL(declined_page_views, 0)` on every day, in both GA4 views. On 2026-10-23 the export held 456 page views, 217 of them declined, and its 45 active users, 97 sessions and 239 accepted page views match the Data API's figures for the day.

The Search Console views keep web search only. `search_console_pages` strips the query string and fragment from the export's URLs and sums the rows that then match, as the history loader does.

`cloudflare_daily` reads `web_history.cloudflare_daily` (see "Cloudflare page loads") and renames `date` to `day`. Its `page_loads` count every visitor, whatever their consent, so they run above GA4's page views.

`cloudflare_pages_daily` reads `web_history.cloudflare_pages_daily` (see "Page loads per path") and renames `date` to `day`. It holds only the paths the capture asked for, the prototypes app's pages under `/prototypes`, so its rows do not sum to `cloudflare_daily`.

`model_spend_daily` reads the standard usage cost export, `billing_export.gcp_billing_export_v1_*`, and keeps only the projects in `spend_callers` (`reporting.auto.tfvars`), labelled with their caller, since the billing account also bills projects outside DFO. Add each Gemini caller's AI Studio key project there. Cloud Billing keeps adding cost to a day for about a day after it ends, so the view keeps only days before yesterday (UTC), and every day it holds is whole. `credits` is negative and `net_cost` is `cost` plus `credits`.

`tests/reporting_*.test.sh` in `infra/stacks/telemetry` run each view over literal source rows and fail on any row that differs from the ones they pin. Run them by hand after changing a view.

### Switching a source on

A view cannot name a table that does not exist, so `reporting_sources` in `reporting.auto.tfvars` lists the source groups whose tables exist, and only their views and authorised-view entries are created. Add a group once the tables below exist, and apply.

| Group              | Views                                             | Tables that must exist                                                                                                                                                                            |
| ------------------ | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `logs`             | the three service views and `deploys`             | `logs_daily.requests_daily`, `routes_daily`, `errors_daily` and `deploys`, from the first `dfo-prod-logs-daily` run                                                                               |
| `mcp`              | `mcp_daily`                                       | `logs_daily.mcp_daily`, from the first `dfo-prod-logs-daily` run                                                                                                                                  |
| `website_requests` | `website_requests_daily`                          | `logs_daily.website_requests_daily`, from the first `dfo-prod-logs-daily` run                                                                                                                     |
| `website_pages`    | `website_page_views_daily`                        | `logs_daily.website_requests_daily`, and `web_history.website_page_history` from `scripts/load-website-page-history.sh`                                                                           |
| `website`          | `product_events_daily`, `account_returns_daily`   | `website_export.event`, from the website export Job's first run                                                                                                                                   |
| `accounts`         | `accounts_daily`                                  | `website_export.account_daily`, from the first website export Job run that writes it                                                                                                              |
| `langfuse`         | `ai_turns`, `ai_observations_daily`               | `langfuse_export.observations`, from the Langfuse export Job's first run                                                                                                                          |
| `ga4`              | `ga4_daily`, `ga4_pages_daily`, `ga4_user_ranges` | an `analytics_<property id>.events_YYYYMMDD` table, and `web_history.ga4_daily` and `ga4_pages_daily` from `scripts/load-ga4-history.sh`. Terraform creates `web_history.ga4_user_ranges`.        |
| `search_console`   | `search_console_daily`, `search_console_pages`    | `searchconsole.searchdata_site_impression` and `searchdata_url_impression`, and `web_history.search_console_daily` and `search_console_pages_daily` from `scripts/load-search-console-history.sh` |
| `cloudflare`       | `cloudflare_daily`                                | `web_history.cloudflare_daily`, from `scripts/load-cloudflare-history.sh`                                                                                                                         |
| `cloudflare_pages` | `cloudflare_pages_daily`                          | `web_history.cloudflare_pages_daily`, from `scripts/load-cloudflare-pages-history.sh`                                                                                                             |
| `billing`          | `model_spend_daily`                               | a `billing_export.gcp_billing_export_v1_*` table                                                                                                                                                  |

`bq ls prod-fin-observatory:<dataset>` lists a dataset's tables.

## Edge request logs

`edge_logs.tf` creates `dfo-prod-edge-logs-prod-fin-observatory`, the bucket the edge-logs stack's Cloudflare Logpush job writes dataset-read request lines to, one gzipped NDJSON batch at a time under `http_requests/<YYYYMMDD>/`. The lines hold raw client IPs, so batches (`*.log.gz`) are deleted three days after they are written, which leaves time to repair a fault in the load into BigQuery and soft delete is off. Cloudflare's `logpush@cloudflare-data.iam.gserviceaccount.com` holds `roles/storage.objectAdmin` on the bucket. The planner holds no object grant on it, since no pull-request plan runs the edge-logs stack. Copy the `edge_logs_bucket` output into the edge-logs stack's `edge_logpush_bucket`. [`infra/dfo-prod/edge-logs/README.md`](../edge-logs/README.md) has the order to turn the job and the cache on, and [`infra/dfo-prod/edge/README.md`](../edge/README.md), "Logpush", the fields and the cost.

## Analytics repo

The private repository `DevelopmentFinanceObservatory/analytics` holds a dbt project that turns the raw usage data into usage metrics. Every metric's logic lives there. This stack holds only the datasets the project writes and the accounts that run it (`analytics.tf`). The project reads thirteen source datasets: `dfo_logs`, `website_export`, `langfuse_export`, `logs_daily`, `web_history`, `edge_export`, `studio_grades`, `repo_search`, `lighthouse`, `replay_probe`, `citation_probe`, `topics` and `langfuse_specs`. The last eight are written by the repository's own Python jobs ("Analytics jobs").

Each dbt target writes one EU dataset:

| Dataset         | Written by                                              | Table expiration |
| --------------- | ------------------------------------------------------- | ---------------- |
| `analytics`     | `dfo-prod-analytics-runner`, the `prod` target          | none             |
| `analytics_ci`  | `dfo-prod-analytics-ci`, the `ci` target                | 1 day            |
| `analytics_dev` | analytics developers' own credentials, the `dev` target | 7 days           |

`dfo-prod-analytics-ci` runs the repository's `dbt-build` CI job. `dfo-prod-analytics-runner` runs the scheduled dbt build, the `dfo-prod-analytics-dbt` Job. Each account holds `roles/bigquery.jobUser` on the project, `WRITER` on its own dataset alone, and `READER` on the twelve sources. The runner writes only `analytics`, so a model the analytics repository places in another dataset with `+schema` fails at build until `analytics.tf` grants the runner `WRITER` on that dataset.

The principals secret's `analytics_developers` object lists the people who build models against prod data. Each gets `roles/bigquery.jobUser` on the project, `READER` on the twelve sources, and `WRITER` on `analytics_dev`. `dfo_logs` holds request IPs and user agents, so a developer reads those too. Someone who only reads the dashboard belongs in `readers` instead. Every developer builds into the one `analytics_dev` dataset, so the last build of a model replaces anyone else's. The analytics repository's `DBT_BIGQUERY_DEV_DATASET` variable points a developer's build at another dataset, which needs its own grant.

The CI job reaches `dfo-prod-analytics-ci` through Workload Identity Federation on the shared GitHub pool, so the account has no key. `analytics_ci_wif` admits only a run on `refs/heads/main`, keyed on `attribute.repo_ref` as `dfo-dev-sdk-e2e` is, since the account reads `dfo_logs` with its request IPs and user agents and a pull request must not mint a token for it. The `dbt-build` job queries BigQuery only on pushes to main. The pool's attribute condition admits only the repositories in `foundation`'s `github_repositories`, so the id (1464310463) sits in both stacks: the `analytics` entry in `infra/dfo-prod/foundation/env.auto.tfvars` and `analytics_repository_id` in this directory's `env.auto.tfvars`. Foundation and telemetry apply on merge. Where `analytics_repository_id` is null, the binding does not exist and the `dbt-build` job is skipped. After the apply, set the repository variables the job reads:

```sh
gh variable set GCP_WIF_PROVIDER --repo DevelopmentFinanceObservatory/analytics \
  --body "$(terraform -chdir=infra/dfo-prod/foundation output -raw workload_identity_provider)"
gh variable set GCP_CI_SERVICE_ACCOUNT --repo DevelopmentFinanceObservatory/analytics \
  --body dfo-prod-analytics-ci@prod-fin-observatory.iam.gserviceaccount.com
```

The repository's `Deploy` workflow pushes its job image to the Docker repository `analytics` in Artifact Registry (`europe-west1-docker.pkg.dev/prod-fin-observatory/analytics`, output `analytics_image_repository`) as `dfo-prod-analytics-deployer`, which holds `roles/artifactregistry.writer` on that repository and, with `analytics_jobs_enabled` on, the grants that move the Jobs to a new image ("Analytics jobs"). The repository keeps the ten newest images and deletes older tagged ones after 30 days. `analytics_deployer_wif` admits only a job on `refs/heads/main` that declares the `production` GitHub Environment, keyed on `attribute.repo_env_ref` as `dfo-ai-deployer` is, so a pull request cannot push an image. It shares `analytics_repository_id` with the CI binding and is absent while that is null. Give the analytics repository a `production` Environment whose deployment branch policy admits main alone, and set `GCP_DEPLOY_SERVICE_ACCOUNT` to the `analytics_deployer_service_account_email` output.

## Analytics jobs

Twelve Cloud Run Jobs in `europe-west1` run the analytics repository's image, declared in `analytics_jobs.tf`. The image has no entrypoint, so each Job's args are its whole command line:

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
| `dfo-prod-analytics-topics-specs`     | `python -m dfo_analytics.topics specs`                                    | `dfo-prod-analytics-topic-specs` | Mondays at 08:00                  | 60 minutes   | 2 GiB  |
| `dfo-prod-analytics-call-specs`       | `python -m dfo_analytics.extract.observation_specs`                       | `dfo-prod-analytics-call-specs`  | hourly at minute 35, not 04 to 06 | 20 minutes   | 1 GiB  |

No Job retries a failed task, so the next scheduled run is the retry, and each timeout ends an execution before the next trigger. The edge extract runs at minute 5 so the build at minute 25 reads its load, and the freshness check at minute 50 reads the sources after both. The freshness Job exists only once `analytics_dbt_schedule_enabled` is on, since it checks the sources the scheduled build reads. The grade Job sets `GRADE_RUN_TIMEOUT_MINUTES` to 60 and its task timeout from the same number, so each run finds the last run's lease ended or lapsed. An edge object at the extract's 256 MiB cap peaks near 1.3 GiB, hence its 2 GiB. The Lighthouse probe makes 15 PageSpeed Insights calls in sequence, each up to 180 seconds with three tries, a worst case near 2.3 hours with backoff, so its timeout is 3 hours. The citation probe runs its three providers in parallel threads, each asking 60 times in sequence with each ask capped at 20 minutes; a month's run takes a few hours, and its 24-hour timeout ends only a pathological one.

The three topics Jobs run one command, `python -m dfo_analytics.topics`, with a pass as its argument: `variables` labels the DFO variables from the origin catalogue, `turns` labels the Studio turns in `langfuse_export` from the last 365 days, and `specs` labels the API specs callers use, from the request paths in `analytics.stg_log_lines` from 2026-10-24. The pass does not read `dfo_logs`. Its account is the only job account with `READER` on `analytics`, and `stg_log_lines` keeps the delivery lines' `json_payload`, which carries user agents and hashed IP caller ids (`ip:<hash>`). Each pass is its own Job with its own secrets, reads, invoker grant, alerts and timeout. The `turns` pass starts at 05:45, after the grader's 04:30 start and 60-minute timeout, so it reads the turns the grader has read. Each run labels at most 50,000 items (`TOPICS_MAX_ITEMS`), 10 calls at a time (`TOPICS_CONCURRENCY`); `variables` is capped at 20,000, since each of its requests carries about 2,000 input tokens and its rate is unmeasured, and `specs` makes one call at a time, since a members call can take one of the apis instance's two materialise permits and the door refuses 503 while both are held. The task timeout is 3600 s. Each run stops starting chunks 50 minutes in (`TOPICS_RUN_DEADLINE_MINUTES`) and exits 0. The `variables` and `turns` passes and the grader share the TypeSafe key, and `specs` calls no model, so `variables` starts on Mondays at 07:00, after the `turns` pass's start and timeout, and `specs` an hour later at 08:00. The Jobs read the dbt seed `dbt/seeds/topic_taxonomy.csv` from the image's `/app`. The Jobs write `topics`, an EU dataset in `analytics.tf` whose tables the Jobs create through the analytics repository's `ensure_table`, so Terraform declares none and the Jobs own the schemas. The analytics models over those tables need the tables to exist, so before any analytics change with models over `topics` merges, run the passes as "Bootstrapping the topics passes" gives and confirm all six tables exist: `variable_topics`, `turn_topics`, `spec_members`, `item_attempts`, `key_complete` and `catalogue_variables`. The `specs` pass resolves its first canary against the prod apis service, so it needs `dfo-prod-apis` serving the spec the image names in `BOOTSTRAP_SPEC`. The topics Jobs run in UTC like the others, so `turns` at 05:45 stays after the grader's timeout through the summer clock change.

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

Each Job has its own account, `dfo-prod-analytics-edge`, `dfo-prod-analytics-grader`, `dfo-prod-analytics-repos`, `dfo-prod-analytics-lighthouse`, `dfo-prod-analytics-replay` and `dfo-prod-analytics-citations`, with `roles/bigquery.jobUser` on the project and `WRITER` on its dataset alone. The grader also holds `READER` on `langfuse_export`, the turns it grades. The three topics accounts, `dfo-prod-analytics-topic-vars`, `dfo-prod-analytics-topic-turns` and `dfo-prod-analytics-topic-specs` (service account ids allow 30 characters), each hold `WRITER` on `topics`; `topic-turns` also holds `READER` on `langfuse_export`, and `topic-specs` holds `READER` on `analytics`, whose `stg_log_lines` it reads. The observation specs account, `dfo-prod-analytics-call-specs`, holds `WRITER` on `langfuse_specs` and `READER` on `langfuse_export`. All eight datasets are analytics sources, so the runner, the CI account and the analytics developers read them. The datasets, the ten accounts and these grants exist whatever `analytics_jobs_enabled` says, since the analytics changes that write the datasets need them first.

The edge extract reads `EDGE_LOGS_BUCKET` (`dfo-prod-edge-logs-prod-fin-observatory`, the bucket Cloudflare Logpush writes to, on which its account holds `roles/storage.objectViewer`), `EXPORT_BQ_PROJECT` and `EDGE_EXPORT_DATASET`, and `CALLER_HMAC_KEY` from the secret `dfo-prod-caller-hmac-key`, the key the website and dfo-apis use, so one client carries one caller in all three. The grader reads `GRADE_BQ_PROJECT`, `GRADE_SOURCE_DATASET`, `GRADE_DATASET`, `GRADE_RUN_TIMEOUT_MINUTES`, `LANGFUSE_BASE_URL` (`https://cloud.langfuse.com`) and `LANGFUSE_EXPORT_ENVIRONMENT` (`dfo-prod-ai`, the environment the ai service tags its traces with), with `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` from `dfo-prod-langfuse-public-key` and `dfo-prod-langfuse-secret-key`, the pair the ai service exports with, and the key of the decision backend `analytics_grade_decision_backend` selects (`GRADE_DECISION_BACKEND`): `TYPESAFE_API_KEY` from `dfo-prod-analytics-grader-typesafe-api-key` for Jev, the default, or `GOOGLE_API_KEY` from `dfo-prod-analytics-grader-gemini-api-key` for Gemini. The Job mounts the selected backend's key alone. The topics `variables` and `turns` Jobs mount the grader's TypeSafe key as well (`specs` calls no model), so it needs a live version whatever backend is selected. The topics Jobs read `TOPICS_BQ_PROJECT`, `TOPICS_DATASET` (`topics`), `TOPICS_CONCURRENCY`, `TOPICS_MAX_ITEMS` and `TOPICS_RUN_DEADLINE_MINUTES` (50), and leave `TOPICS_TAXONOMY_PATH` unset, so the Jobs read `dbt/seeds/topic_taxonomy.csv` from the image's `/app`. `variables` also reads `TOPICS_CATALOGUE_BUCKET` (`dfo-prod-origin-catalogue-prod-fin-observatory`, the apis stack's origin catalogue bucket, on which `topic-vars` holds `roles/storage.objectViewer`). `turns` reads `TOPICS_SOURCE_DATASET` (`langfuse_export`), `TOPICS_TURN_LOOKBACK_DAYS` (365), `LANGFUSE_BASE_URL` and `LANGFUSE_EXPORT_ENVIRONMENT` as the grader does. `specs` reads `TOPICS_APIS_URL` and `TOPICS_APIS_AUDIENCE`, the apis service's URL as for the replay probe, `TOPICS_SPEC_SERVICES` (the apis service, `dfo-prod-apis`, and `dfo-prod-website`, comma-separated), and `TOPICS_ANALYTICS_DATASET` (`analytics`). The observation specs Job reads `SPECS_BQ_PROJECT`, `SPECS_SOURCE_DATASET` (`langfuse_export`), `SPECS_DATASET` (`langfuse_specs`), `LANGFUSE_BASE_URL` and `LANGFUSE_EXPORT_ENVIRONMENT` as the grader does, with `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` from the same two secrets. The probes read their project and dataset from `REPO_SEARCH_BQ_PROJECT` and `REPO_SEARCH_DATASET`, `LIGHTHOUSE_BQ_PROJECT` and `LIGHTHOUSE_DATASET`, `REPLAY_BQ_PROJECT` and `REPLAY_DATASET`, and `CITATION_PROBE_BQ_PROJECT` and `CITATION_PROBE_DATASET`, and their keys from secrets of their own:

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

Terraform creates each Job with the image in `analytics_jobs_image`, a sha-tagged image from the analytics registry, and then ignores the Job's image, so a deploy moves the Jobs without reading as drift. `dfo-prod-analytics-deployer` holds `roles/run.developer` on each Job and `roles/iam.serviceAccountUser` on each Job's account, which `gcloud run jobs update <job> --image <image> --region europe-west1 --project prod-fin-observatory` needs. The analytics repository's `Deploy` workflow runs that update after each push for every Job named in its repository variable `ANALYTICS_JOBS` (DevelopmentFinanceObservatory/analytics#7). Set the variable to the eleven Jobs' names once they exist, `dfo-prod-analytics-dbt dfo-prod-analytics-edge dfo-prod-analytics-grade dfo-prod-analytics-repos dfo-prod-analytics-lighthouse dfo-prod-analytics-replay dfo-prod-analytics-citations dfo-prod-analytics-topics-variables dfo-prod-analytics-topics-turns dfo-prod-analytics-topics-specs dfo-prod-analytics-call-specs`; until then a Job keeps the image it was created with. The freshness Job exists only once `analytics_dbt_schedule_enabled` is on, and a named Job that does not exist fails the deploy, so add `dfo-prod-analytics-freshness` to the variable after that apply.

Cloud Scheduler starts each Job as `dfo-prod-analytics-scheduler`, which holds `roles/run.invoker` on each Job and nothing else, through the triggers `dfo-prod-analytics-dbt-tick`, `dfo-prod-analytics-edge-tick`, `dfo-prod-analytics-grade-tick`, `dfo-prod-analytics-freshness-tick`, `dfo-prod-analytics-repos-tick`, `dfo-prod-analytics-lighthouse-tick`, `dfo-prod-analytics-replay-tick`, `dfo-prod-analytics-citations-tick`, `dfo-prod-analytics-topics-variables-tick`, `dfo-prod-analytics-topics-turns-tick`, `dfo-prod-analytics-topics-specs-tick` and `dfo-prod-analytics-call-specs-tick`. The dbt trigger exists only once `analytics_dbt_schedule_enabled` is true, which also disables the `dfo-prod-logs-daily` scheduled query and drops its absence alert, since the hourly build replaces it, and moves the `dfo_reporting` views over its tables to the `analytics` tables (see "Reporting views"). The `logs_daily` tables stay as the archive the build copies its days before 2026-10-24 from. A probe's trigger exists only while its entry in the map `analytics_probes_enabled` is true; every entry defaults to false, so each probe's Job exists with no trigger and no absence alert until its switch is on. The map's keys are `repos`, `lighthouse`, `replay`, `citations`, `topics-variables`, `topics-turns`, `topics-specs` and `call-specs`. The first three of the last four are the topics passes and `call-specs` is the observation specs Job; all four are switched on like probes after a canary execution, and the map needs `analytics_jobs_enabled`.

To run a Job outside its schedule, or with other args or settings, start one execution. Overrides need `run.jobs.runWithOverrides` on the Job, which a project owner holds:

```sh
gcloud run jobs execute dfo-prod-analytics-dbt --region europe-west1 --project prod-fin-observatory --wait \
  --args='dbt,test,--target,prod,--select,tag:cutover'
```

`--args` takes the whole command line, comma-separated. `--update-env-vars` sets a setting for that execution alone, such as `DBT_MAXIMUM_BYTES_BILLED` for a dbt run that reads more than 20 GB, or `EDGE_REJECT_OBJECTS` for an edge run that moves past a held batch. The extract records a rejected object, so one execution is enough.

### Switching the Jobs on

1. Apply this stack with `analytics_jobs_enabled` false, which creates `edge_export` and its three tables, `studio_grades`, the four probe datasets and their tables, the empty `topics` and `langfuse_specs` datasets, the ten Job accounts and their dataset grants, and the empty Gemini and probe key secrets. The apis stack applies first and creates `dfo-prod-verify-principal`.

2. Add the grader's TypeSafe key as the secret's first version, with `gcloud secrets versions add dfo-prod-analytics-grader-typesafe-api-key --data-file=- --project=prod-fin-observatory` reading the key from stdin, and each probe key the same way: a GitHub token that may search public code to `dfo-prod-analytics-repos-github-token`, a PageSpeed Insights API key to `dfo-prod-analytics-lighthouse-psi-api-key`, and the OpenAI and Gemini keys to `dfo-prod-analytics-citations-openai-api-key` and `dfo-prod-analytics-citations-gemini-api-key`. The citation probe skips a provider whose key is unset, and the Job mounts no Anthropic key, so it asks OpenAI and Gemini. The edge logs bucket must exist, with the edge-logs stack's Logpush job writing to it.

3. Merge the analytics changes that add the edge extract, the turn grader, the `logs_daily` port and the four probes, and let the `Deploy` workflow push the image. Note its sha. The replay probe also needs the dfo-apis release that adds the verify route and the share sample.

4. Set `analytics_jobs_enabled = true` and `analytics_jobs_image = "europe-west1-docker.pkg.dev/prod-fin-observatory/analytics/dfo-analytics:<sha>"` in `env.auto.tfvars`, merge, and let the apply run. It creates every Job in the table under "Analytics jobs" except freshness (the output `analytics_job_names` lists them), the edge and grade triggers, their alerts, the edge object alert, the call-specs lost-rows metric and its alert, and the invoker grants on `dfo-prod-apis` for the replay and topics `specs` accounts, and no dbt trigger, probe trigger or freshness Job. The grade absence alert opens within minutes; run `gcloud run jobs execute dfo-prod-analytics-grade --region europe-west1 --project prod-fin-observatory` to close it. The probes have no trigger and no absence alert yet, since `analytics_probes_enabled` is false for each; their canary executions and switches follow in "Switching a probe on". Each probe's canary also fills its source table, which `dbt source freshness` needs before step 7: it errors on an empty table.

5. Run the `logs_daily` cutover as one-off executions of `dfo-prod-analytics-dbt` with their args replaced, in the order the analytics repository's README gives: `dbt,run-operation,copy_logs_daily_archive,--target,prod`, then `dbt,build,--target,prod,--select,tag:log_fed+,--exclude,tag:cutover,--vars,{log_lookback_days: N}` with N the days from 2026-10-24 through yesterday, then `dbt,test,--target,prod,--select,tag:cutover`. Each must succeed before the next starts.

6. Check that the `dfo_reporting` views over `logs_daily` and the same SELECTs over `analytics` agree, since the switch moves the views from one to the other. Run the script below as a project owner, with `bq query --use_legacy_sql=false --location=EU < parity.sql`, after a scheduled `dfo-prod-logs-daily` run and a one-off `dfo-prod-analytics-dbt` build have both covered `last_day`. Set `last_day` to the day before yesterday, the newest day both sources hold whole. Each of the seven queries compares one view, `EXCEPT DISTINCT` both ways over the same days, and every one must return zero rows. A row names the side that holds it, and the switch waits until the analytics model is fixed. The latency quantiles come from `APPROX_QUANTILES` and `callers_sketch` is an HLL++ sketch, so two builds over the same rows can differ in those columns alone. A row that differs only there is checked instead by the cutover's `matches_legacy` tests, which compare each quantile within its tolerance and each sketch by its distinct count.

   ```sql
   DECLARE first_day DATE DEFAULT DATE '2026-10-24';
   DECLARE last_day DATE DEFAULT DATE '2026-11-17';

   -- service_requests_daily
   WITH
     v AS (SELECT * FROM `prod-fin-observatory.dfo_reporting.service_requests_daily` WHERE day BETWEEN first_day AND last_day),
     a AS (SELECT day, service, requests, status_4xx, status_5xx, latency_p50_ms, latency_p95_ms, latency_p99_ms FROM `prod-fin-observatory.analytics.requests_daily` WHERE day BETWEEN first_day AND last_day)
   SELECT 'logs_daily only' AS side, * FROM (SELECT * FROM v EXCEPT DISTINCT SELECT * FROM a)
   UNION ALL
   SELECT 'analytics only' AS side, * FROM (SELECT * FROM a EXCEPT DISTINCT SELECT * FROM v);

   -- service_routes_daily
   WITH
     v AS (SELECT * FROM `prod-fin-observatory.dfo_reporting.service_routes_daily` WHERE day BETWEEN first_day AND last_day),
     a AS (SELECT day, service, method, route, requests, status_4xx, status_5xx, latency_p50_ms, latency_p95_ms, latency_p99_ms FROM `prod-fin-observatory.analytics.routes_daily` WHERE day BETWEEN first_day AND last_day)
   SELECT 'logs_daily only' AS side, * FROM (SELECT * FROM v EXCEPT DISTINCT SELECT * FROM a)
   UNION ALL
   SELECT 'analytics only' AS side, * FROM (SELECT * FROM a EXCEPT DISTINCT SELECT * FROM v);

   -- service_errors_daily
   WITH
     v AS (SELECT * FROM `prod-fin-observatory.dfo_reporting.service_errors_daily` WHERE day BETWEEN first_day AND last_day),
     a AS (SELECT day, resource_type, service, logger, severity, entries FROM `prod-fin-observatory.analytics.errors_daily` WHERE day BETWEEN first_day AND last_day)
   SELECT 'logs_daily only' AS side, * FROM (SELECT * FROM v EXCEPT DISTINCT SELECT * FROM a)
   UNION ALL
   SELECT 'analytics only' AS side, * FROM (SELECT * FROM a EXCEPT DISTINCT SELECT * FROM v);

   -- mcp_daily
   WITH
     v AS (SELECT * FROM `prod-fin-observatory.dfo_reporting.mcp_daily` WHERE day BETWEEN first_day AND last_day),
     a AS (SELECT day, caller_kind, client, request, outcome, calls, callers_sketch FROM `prod-fin-observatory.analytics.mcp_daily` WHERE day BETWEEN first_day AND last_day)
   SELECT 'logs_daily only' AS side, * FROM (SELECT * FROM v EXCEPT DISTINCT SELECT * FROM a)
   UNION ALL
   SELECT 'analytics only' AS side, * FROM (SELECT * FROM a EXCEPT DISTINCT SELECT * FROM v);

   -- website_requests_daily
   WITH
     v AS (SELECT * FROM `prod-fin-observatory.dfo_reporting.website_requests_daily` WHERE day BETWEEN first_day AND last_day),
     a AS (SELECT day, route, kind, bot, status_class, requests, callers_sketch FROM `prod-fin-observatory.analytics.website_requests_daily` WHERE day BETWEEN first_day AND last_day)
   SELECT 'logs_daily only' AS side, * FROM (SELECT * FROM v EXCEPT DISTINCT SELECT * FROM a)
   UNION ALL
   SELECT 'analytics only' AS side, * FROM (SELECT * FROM a EXCEPT DISTINCT SELECT * FROM v);

   -- website_page_views_daily
   WITH
     v AS (SELECT * FROM `prod-fin-observatory.dfo_reporting.website_page_views_daily` WHERE day BETWEEN first_day AND last_day),
     a AS (SELECT day, page_views, bot_page_views FROM `prod-fin-observatory.analytics.website_page_views_daily` WHERE day BETWEEN first_day AND last_day)
   SELECT 'logs_daily only' AS side, * FROM (SELECT * FROM v EXCEPT DISTINCT SELECT * FROM a)
   UNION ALL
   SELECT 'analytics only' AS side, * FROM (SELECT * FROM a EXCEPT DISTINCT SELECT * FROM v);

   -- deploys
   WITH
     v AS (SELECT * FROM `prod-fin-observatory.dfo_reporting.deploys` WHERE DATE(deployed_at) BETWEEN first_day AND last_day),
     a AS (SELECT service, revision, first_request AS deployed_at FROM `prod-fin-observatory.analytics.deploys` WHERE NOT before_source AND DATE(first_request) BETWEEN first_day AND last_day)
   SELECT 'logs_daily only' AS side, * FROM (SELECT * FROM v EXCEPT DISTINCT SELECT * FROM a)
   UNION ALL
   SELECT 'analytics only' AS side, * FROM (SELECT * FROM a EXCEPT DISTINCT SELECT * FROM v);
   ```

7. Check that each probe's canary execution has succeeded, then set `analytics_dbt_schedule_enabled = true`, merge, and let the apply run. It creates the dbt trigger and its alert, the freshness Job, its trigger and its alert, disables the `dfo-prod-logs-daily` scheduled query, and moves the seven views to `analytics`.

### Switching a probe on

Each probe is switched on alone, in this order, with the probe's entry in `analytics_probes_enabled` (`repos`, `lighthouse`, `replay`, `citations`, `topics-variables`, `topics-turns`, `topics-specs` or `call-specs`) as the last step. Until then the Job, its account, its secrets and its tables exist and a manual execution works, and the probe has no trigger and no absence alert.

1. Set the probe's secret values (the table under "Analytics jobs": the GitHub token for `repos`, the PageSpeed Insights key for `lighthouse`, the three provider keys for `citations`; `replay` mounts the verify principal and the export key, which the apis and website stacks generate; the topics passes mount keys that already exist; `call-specs` mounts `dfo-prod-langfuse-public-key` and `dfo-prod-langfuse-secret-key`, the pair the grader and the topics `turns` pass mount, so it needs no new secret).

2. Build the image from the analytics repository's `Deploy` workflow with the probe's code, and set `analytics_jobs_image` to it, or move the Job with `gcloud run jobs update <job> --image <image> --region europe-west1 --project prod-fin-observatory`.

3. Run one canary: `gcloud run jobs execute <job> --region europe-west1 --project prod-fin-observatory --wait` (add `--async` for `dfo-prod-analytics-citations`, which takes a few hours). Check three things:

   - The execution exits 0.
   - The probe's tables hold rows for the expected inputs: for `repos`, `repo_search.runs` has a row for each query; for `lighthouse`, `lighthouse.results` has a row for each of the 15 URLs and `lighthouse.runs` records the run; for `replay`, `replay_probe.runs` has a row for the run whose status is not a failure, and `slot_results` has rows for the shares sampled; for `call-specs`, `langfuse_specs.observation_specs` holds `read` rows; for the topics passes, the bootstrap below has run and `topics.variable_topics` (`topics-variables`), `topics.turn_topics` (`topics-turns`) or `topics.spec_members` (`topics-specs`) holds rows; for `citations`, `citation_probe.runs` has a row for each provider and question and `answers` has a row for each answered ask.
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

6. Switch each pass on with its entry in `analytics_probes_enabled`, only after the analytics models over `topics` have a passing prod dbt build. The schedules, in UTC, are `turns` daily at 05:45, `variables` on Mondays at 07:00 and `specs` on Mondays at 08:00.

## Readers

The principals secret's `readers` object lists the readers of `dfo_reporting` as people, each `group:` or `user:` followed by an address. Each gets `READER` on `dfo_reporting`, and `roles/bigquery.jobUser` and `roles/mcp.toolUser` on the project, and no access to `logs_daily`, `dfo_logs`, `searchconsole`, or any other source dataset.

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

Telemetry applies after `foundation`, which lets the applier write this stack's state and grants it the custom role `dfoInfraApplierTransferConfigs` for the scheduled query.

## Made by hand first

- A local backend init, `just ENV=dfo-prod STACK=telemetry bootstrap`, once `foundation` has applied.
- The principals secret `dfo-prod-telemetry-principals`, written with `scripts/bootstrap-principals.sh` as "Principals secret" describes. Plan fails while it does not exist.
- The Google groups the secret names. The reader grants fail while a reader group does not exist, and an alert group must accept mail from outside its domain, since Cloud Monitoring sends from a google.com address.
- The BigQuery Data Transfer Service agent, `service-<project number>@gcp-sa-bigquerydatatransfer.iam.gserviceaccount.com`. The grant that lets it run `dfo-prod-logs-daily` fails while the agent does not exist, and the applier cannot create it. A project owner creates it once with `gcloud beta services identity create --service=bigquerydatatransfer.googleapis.com --project=prod-fin-observatory`.

## After the first apply

- The analytics repository's id in both stacks and its two repository variables, as "Analytics repo" shows. The repository's `dbt-build` job is skipped until then.
- The analytics Jobs, switched on in the order "Switching the Jobs on" gives.
- In Search Console, under Settings, Bulk data export, a property owner of developmentfinance.org enters the project `prod-fin-observatory`, the dataset `searchconsole`, and the location EU. The first export arrives within 48 hours.
- `dfo-prod-ga4-user-ranges` first runs at the next 06:00 UTC, and `ga4_user_ranges` is empty until then. To fill it sooner, run it by hand as "GA4 unique users" shows.
- `dfo-prod-logs-daily` first runs at the next 02:00 UTC. To run it sooner, start a manual run from the BigQuery console's Scheduled queries page.
