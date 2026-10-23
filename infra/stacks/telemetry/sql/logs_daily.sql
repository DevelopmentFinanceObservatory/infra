-- The logs_daily scheduled query, a Terraform template (logs_daily.tf). It
-- reads ${source}, the view logs_daily.entries (sql/entries.sql), and writes
-- five tables in ${dataset}, creating them on the first run. The view joins
-- two sources at the cut-off ${cutoff}: ${live_source}, the linked dataset
-- of the telemetry sink's bucket, from the cut-off on, and backfill_entries,
-- the Cloud Run entries copied from _Default, before it.
--
-- The source's oldest day is partial, since the copy or retention cut
-- entries part way through it, so the oldest whole day is the one after.
-- The run's own day is partial too, so requests_daily, routes_daily,
-- errors_daily and mcp_daily read entries before the current UTC day only,
-- and every day they hold is whole. They replace the days from
-- requests_daily's latest loaded day minus one through yesterday, and from
-- the oldest whole day when requests_daily is empty. The start never falls
-- before a floor. While
-- ${live_source} reaches back to the cut-off, the view has no gap and the
-- floor is the source's oldest whole day. Once retention has moved
-- ${live_source}'s oldest entry past the cut-off, the view has a gap
-- between the backfill and that entry, and the floor is ${live_source}'s
-- oldest whole day. Either way every day a run deletes is
-- a day it reloads in full, even after an outage longer than retention.
-- errors_daily and mcp_daily share requests_daily's start, so a stretch with
-- no warnings or no MCP calls cannot widen their window. A source with no
-- entries, or an empty ${live_source} once requests_daily holds days, loads
-- and deletes nothing, since the start is then NULL.
--
-- deploys gains a row for each revision it has not seen, timed at the
-- revision's first request across the whole source, today included, and
-- never changes a row once written, so an earlier entry that reaches the
-- source after the run does not move it. before_source is true, as of the
-- run that records the revision, when no other revision of its service
-- served a request earlier in the source. A revision with an earlier
-- sibling was deployed after the source began. One without was serving when
-- the source began, or is the first after a service-wide silence longer
-- than retention, or the first of a new service. Its first request is not a
-- known deploy, so deploy markers read only rows where before_source is
-- false. Recording it anyway keeps it out of later runs, which would
-- otherwise time it at whatever request survives retention and mark a
-- deploy weeks late.
--
-- mcp_daily counts the combined MCP server's per-call log lines, which
-- harness.combined_mcp in dfo-ai writes, one per tool call, resource read,
-- resource list and initialize:
--   combined mcp call <request> outcome=<outcome> revision=<revision>
--     caller=<caller> trace_id=<trace id> client=<client> client_version=...
--   combined mcp initialize outcome=<outcome> revision=<revision>
--     caller=<caller> client=<client> client_version=...
-- <request> is tool=<name>, resource or resource_list. A tool name is bare
-- when it is a plain name and a JSON string otherwise, <client> is None or a
-- JSON string, and <caller> is None or the x-dfo-caller header, whose prefix
-- before the first colon is its kind: user, key, ip or conversation, and
-- 'other' for any other prefix. The query reads those fields only. A client
-- chooses its name and the tool it calls, and an outcome can name any
-- exception, so each is written as logged when it matches a fixed pattern
-- and as 'other' otherwise, and no free text reaches the table. The caller
-- reaches it only inside callers_sketch, an HLL++ sketch. A line that starts
-- "combined mcp " in any other shape counts as request 'unparsed', with
-- caller kind, client and outcome 'none', so a change of log format shows
-- as unparsed calls.
-- Days are UTC.

DECLARE source_first_day, load_from DATE;
DECLARE live_first TIMESTAMP;
-- A combined MCP line, with the call's request in group 1, outcome in 2 and
-- caller in 3, or initialize in 4, its outcome in 5 and caller in 6, and the
-- client in 7. The caller is matched lazily up to the fixed field after it,
-- since a header value may hold spaces.
DECLARE mcp_line STRING DEFAULT r'(?s)^combined mcp (?:call (tool=(?:[A-Za-z0-9_.-]+|"(?:[^"\\]|\\.)*")|resource|resource_list) outcome=(.*?) revision=\S* caller=(.*?) trace_id=\S*|(initialize) outcome=(.*?) revision=\S* caller=(.*?)) client=(None|"(?:[^"\\]|\\.)*") client_version=.*$';

CREATE TABLE IF NOT EXISTS `${dataset}.requests_daily` (
  day DATE NOT NULL,
  service STRING NOT NULL,
  requests INT64 NOT NULL,
  status_4xx INT64 NOT NULL,
  status_5xx INT64 NOT NULL,
  latency_p50_ms FLOAT64,
  latency_p95_ms FLOAT64,
  latency_p99_ms FLOAT64
)
PARTITION BY day
OPTIONS (description = 'Cloud Run requests per UTC day and service, with status counts and approximate latency quantiles.');

CREATE TABLE IF NOT EXISTS `${dataset}.routes_daily` (
  day DATE NOT NULL,
  service STRING NOT NULL,
  method STRING,
  route STRING,
  requests INT64 NOT NULL,
  status_4xx INT64 NOT NULL,
  status_5xx INT64 NOT NULL,
  latency_p50_ms FLOAT64,
  latency_p95_ms FLOAT64,
  latency_p99_ms FLOAT64
)
PARTITION BY day
CLUSTER BY service
OPTIONS (description = 'Cloud Run requests per UTC day, service, method and route, where route is ${normalise_route}(requestUrl).');

CREATE TABLE IF NOT EXISTS `${dataset}.errors_daily` (
  day DATE NOT NULL,
  resource_type STRING NOT NULL,
  service STRING NOT NULL,
  logger STRING,
  severity STRING NOT NULL,
  entries INT64 NOT NULL
)
PARTITION BY day
OPTIONS (description = 'Cloud Run service and job stdout and stderr entries at WARNING or above, per UTC day, service or job, logger and severity. No message text.');

CREATE TABLE IF NOT EXISTS `${dataset}.deploys` (
  service STRING NOT NULL,
  revision STRING NOT NULL,
  first_request TIMESTAMP NOT NULL,
  before_source BOOL NOT NULL
)
OPTIONS (description = 'Each Cloud Run revision that served a request, with the time of its first request. before_source is true for a revision already serving when the logs source began, whose first_request is not its deploy.');

CREATE TABLE IF NOT EXISTS `${dataset}.mcp_daily` (
  day DATE NOT NULL,
  caller_kind STRING NOT NULL,
  client STRING NOT NULL,
  request STRING NOT NULL,
  outcome STRING NOT NULL,
  calls INT64 NOT NULL,
  callers_sketch BYTES
)
PARTITION BY day
OPTIONS (description = 'Combined MCP server tool calls, resource reads, resource lists and initializes per UTC day, caller kind, client, request and outcome, with an HLL++ sketch of the callers. No caller, trace id, URI or other text.');

SET source_first_day = (SELECT DATE(MIN(timestamp)) FROM `${source}`);
SET live_first = (SELECT MIN(timestamp) FROM `${live_source}`);
-- GREATEST returns NULL when any argument is NULL, so each branch reaches it
-- with both arguments set. An empty requests_daily loads the whole source,
-- backfill included, since it has no day to lose. An empty ${live_source}
-- with loaded days gives NULL, so the run deletes nothing it cannot reload.
SET load_from = (
  SELECT
    CASE
      WHEN source_first_day IS NULL THEN NULL
      WHEN MAX(day) IS NULL THEN source_first_day + 1
      WHEN live_first IS NULL THEN NULL
      WHEN live_first > TIMESTAMP '${cutoff}' THEN GREATEST(MAX(day) - 1, DATE(live_first) + 1)
      ELSE GREATEST(MAX(day) - 1, source_first_day + 1)
    END
  FROM `${dataset}.requests_daily`
);

CREATE TEMP TABLE requests AS
SELECT
  DATE(timestamp) AS day,
  JSON_VALUE(resource.labels.service_name) AS service,
  http_request.request_method AS method,
  `${normalise_route}`(http_request.request_url) AS route,
  http_request.status AS status,
  -- latency is a STRUCT of INT64 seconds and nanos, and an entry may omit a
  -- zero component.
  IF(
    http_request.latency IS NULL,
    NULL,
    IFNULL(http_request.latency.seconds, 0) * 1000 + IFNULL(http_request.latency.nanos, 0) / 1e6
  ) AS latency_ms
FROM `${source}`
WHERE timestamp >= TIMESTAMP(load_from)
  AND timestamp < TIMESTAMP(CURRENT_DATE())
  AND resource.type = 'cloud_run_revision'
  AND log_id = 'run.googleapis.com/requests';

BEGIN TRANSACTION;

DELETE FROM `${dataset}.requests_daily` WHERE day >= load_from;
INSERT INTO `${dataset}.requests_daily`
SELECT
  day,
  service,
  COUNT(*),
  COUNTIF(status BETWEEN 400 AND 499),
  COUNTIF(status BETWEEN 500 AND 599),
  APPROX_QUANTILES(latency_ms, 100)[SAFE_OFFSET(50)],
  APPROX_QUANTILES(latency_ms, 100)[SAFE_OFFSET(95)],
  APPROX_QUANTILES(latency_ms, 100)[SAFE_OFFSET(99)]
FROM requests
WHERE day >= load_from
GROUP BY day, service;

DELETE FROM `${dataset}.routes_daily` WHERE day >= load_from;
INSERT INTO `${dataset}.routes_daily`
SELECT
  day,
  service,
  method,
  route,
  COUNT(*),
  COUNTIF(status BETWEEN 400 AND 499),
  COUNTIF(status BETWEEN 500 AND 599),
  APPROX_QUANTILES(latency_ms, 100)[SAFE_OFFSET(50)],
  APPROX_QUANTILES(latency_ms, 100)[SAFE_OFFSET(95)],
  APPROX_QUANTILES(latency_ms, 100)[SAFE_OFFSET(99)]
FROM requests
WHERE day >= load_from
GROUP BY day, service, method, route;

DELETE FROM `${dataset}.errors_daily` WHERE day >= load_from;
INSERT INTO `${dataset}.errors_daily`
SELECT
  DATE(timestamp),
  resource.type,
  COALESCE(JSON_VALUE(resource.labels.service_name), JSON_VALUE(resource.labels.job_name)),
  JSON_VALUE(json_payload.logger),
  severity,
  COUNT(*)
FROM `${source}`
WHERE timestamp >= TIMESTAMP(load_from)
  AND timestamp < TIMESTAMP(CURRENT_DATE())
  AND log_id IN ('run.googleapis.com/stdout', 'run.googleapis.com/stderr')
  AND severity IN ('WARNING', 'ERROR', 'CRITICAL', 'ALERT', 'EMERGENCY')
GROUP BY 1, 2, 3, 4, 5;

DELETE FROM `${dataset}.mcp_daily` WHERE day >= load_from;
INSERT INTO `${dataset}.mcp_daily`
SELECT
  day,
  CASE
    WHEN caller = 'None' THEN 'none'
    ELSE IFNULL(REGEXP_EXTRACT(caller, r'^(user|key|ip|conversation):'), 'other')
  END,
  CASE
    WHEN client = 'None' THEN 'none'
    WHEN REGEXP_CONTAINS(JSON_VALUE(client), r'^[A-Za-z0-9 ._/-]{1,64}$') THEN JSON_VALUE(client)
    ELSE 'other'
  END AS client,
  CASE
    WHEN NOT STARTS_WITH(request, 'tool=') THEN request
    WHEN REGEXP_CONTAINS(SUBSTR(request, 6), r'^[A-Za-z0-9_.-]{1,64}$') THEN SUBSTR(request, 6)
    ELSE 'other'
  END AS request,
  IF(REGEXP_CONTAINS(outcome, r'^[A-Za-z0-9_.-]{1,64}$'), outcome, 'other') AS outcome,
  COUNT(*),
  HLL_COUNT.INIT(NULLIF(caller, 'None'), 14)
FROM (
  SELECT
    DATE(timestamp) AS day,
    IF(parsed, REGEXP_REPLACE(message, mcp_line, r'\1\4'), 'unparsed') AS request,
    IF(parsed, REGEXP_REPLACE(message, mcp_line, r'\2\5'), 'none') AS outcome,
    IF(parsed, REGEXP_REPLACE(message, mcp_line, r'\3\6'), 'None') AS caller,
    IF(parsed, REGEXP_REPLACE(message, mcp_line, r'\7'), 'None') AS client
  FROM (
    SELECT timestamp, message, REGEXP_CONTAINS(message, mcp_line) AS parsed
    FROM (
      SELECT timestamp, JSON_VALUE(json_payload.message) AS message
      FROM `${source}`
      WHERE timestamp >= TIMESTAMP(load_from)
        AND timestamp < TIMESTAMP(CURRENT_DATE())
        AND resource.type = 'cloud_run_revision'
        AND log_id IN ('run.googleapis.com/stdout', 'run.googleapis.com/stderr')
        AND JSON_VALUE(json_payload.logger) = 'harness.combined_mcp'
    )
    -- The server's warnings start "combined mcp: " and are not calls.
    WHERE STARTS_WITH(message, 'combined mcp ')
  )
)
GROUP BY 1, 2, 3, 4, 5;

INSERT INTO `${dataset}.deploys`
SELECT service, revision, first_request, before_source
FROM (
  -- Every revision in the source, recorded or not, so the earliest sibling
  -- can be one deploys already holds.
  SELECT
    service,
    revision,
    first_request,
    first_request = MIN(first_request) OVER (PARTITION BY service) AS before_source
  FROM (
    SELECT
      JSON_VALUE(resource.labels.service_name) AS service,
      JSON_VALUE(resource.labels.revision_name) AS revision,
      MIN(timestamp) AS first_request
    FROM `${source}`
    WHERE resource.type = 'cloud_run_revision'
      AND log_id = 'run.googleapis.com/requests'
    GROUP BY service, revision
  )
) AS seen
WHERE NOT EXISTS (
  SELECT 1
  FROM `${dataset}.deploys` AS known
  WHERE known.service = seen.service AND known.revision = seen.revision
);

COMMIT TRANSACTION;
