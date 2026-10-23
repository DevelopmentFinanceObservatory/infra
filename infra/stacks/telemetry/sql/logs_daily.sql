-- The logs_daily scheduled query, a Terraform template (logs_daily.tf). It
-- reads ${source}, the linked dataset's view of every routed Cloud Run entry,
-- and writes four tables in ${dataset}, creating them on the first run.
--
-- The source's oldest day is partial, since the sink started or retention
-- cut entries part way through it, so the oldest whole day is the one after.
-- requests_daily, routes_daily and errors_daily replace the days from
-- requests_daily's latest loaded day minus one through today, and from the
-- oldest whole day when requests_daily is empty. The start never falls
-- before the oldest whole day, so every day a run deletes is a day it
-- reloads in full, even after an outage longer than the source's retention.
-- errors_daily shares requests_daily's start, so a stretch with no warnings
-- cannot widen its window. A source with no entries loads and deletes
-- nothing, since the start is then NULL.
--
-- deploys gains a row for each revision it has not seen, timed at the
-- revision's first request across the whole source, and never changes a row
-- once written. before_source is true when that first request falls on the
-- source's oldest day as of the run that records it. Such a revision was
-- already serving when the source began, so its first request there is not
-- its deploy, and deploy markers read only rows where before_source is false.
-- Recording it anyway keeps it out of later runs, which would otherwise time
-- it at whatever request survives retention and mark a deploy weeks late.
-- Days are UTC.

DECLARE source_first_day, load_from DATE;

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

SET source_first_day = (SELECT DATE(MIN(timestamp)) FROM `${source}`);
SET load_from = (
  SELECT GREATEST(IFNULL(MAX(day) - 1, source_first_day + 1), source_first_day + 1)
  FROM `${dataset}.requests_daily`
);

CREATE TEMP TABLE requests AS
SELECT
  DATE(timestamp) AS day,
  JSON_VALUE(resource.labels.service_name) AS service,
  http_request.request_method AS method,
  `${normalise_route}`(http_request.request_url) AS route,
  http_request.status AS status,
  TIMESTAMP_DIFF(TIMESTAMP '1970-01-01' + http_request.latency, TIMESTAMP '1970-01-01', MICROSECOND) / 1000 AS latency_ms
FROM `${source}`
WHERE timestamp >= TIMESTAMP(load_from)
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
  AND log_id IN ('run.googleapis.com/stdout', 'run.googleapis.com/stderr')
  AND severity IN ('WARNING', 'ERROR', 'CRITICAL', 'ALERT', 'EMERGENCY')
GROUP BY 1, 2, 3, 4, 5;

INSERT INTO `${dataset}.deploys`
SELECT service, revision, first_request, DATE(first_request) = source_first_day
FROM (
  SELECT
    JSON_VALUE(resource.labels.service_name) AS service,
    JSON_VALUE(resource.labels.revision_name) AS revision,
    MIN(timestamp) AS first_request
  FROM `${source}`
  WHERE resource.type = 'cloud_run_revision'
    AND log_id = 'run.googleapis.com/requests'
  GROUP BY service, revision
) AS seen
WHERE NOT EXISTS (
  SELECT 1
  FROM `${dataset}.deploys` AS known
  WHERE known.service = seen.service AND known.revision = seen.revision
);

COMMIT TRANSACTION;
