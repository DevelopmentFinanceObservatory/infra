-- The rows scripts/load-logs-backfill.sh writes to logs_daily.backfill_entries,
-- read from ${staging}, the copied LogEntry JSON loaded with only the fields
-- this needs (of jsonPayload, logger and message). The output has the column
-- names, types and nesting of dfo_logs._AllLogs for the columns
-- logs_daily.sql reads, and keeps only the entries the telemetry sink's
-- filter (logs.tf) routes. That filter drops the website's usage-event
-- lines, which it finds by message, and json_payload keeps only the logger
-- field, so no message text reaches the table.
SELECT
  timestamp,
  log_id,
  -- LogEntry JSON omits a DEFAULT severity, which _AllLogs spells out.
  IFNULL(severity, 'DEFAULT') AS severity,
  STRUCT(resource.type AS type, resource.labels AS labels) AS resource,
  IF(
    httpRequest IS NULL,
    NULL,
    STRUCT(
      httpRequest.requestMethod AS request_method,
      httpRequest.requestUrl AS request_url,
      httpRequest.status AS status,
      IF(
        latency_s IS NULL,
        NULL,
        STRUCT(
          CAST(TRUNC(latency_s) AS INT64) AS seconds,
          CAST((latency_s - TRUNC(latency_s)) * 1000000000 AS INT64) AS nanos
        )
      ) AS latency
    )
  ) AS http_request,
  IF(
    jsonPayload.logger IS NULL,
    NULL,
    JSON_OBJECT('logger', jsonPayload.logger)
  ) AS json_payload
FROM (
  SELECT
    * REPLACE (
      -- LogEntry JSON carries nanoseconds, which TIMESTAMP truncates.
      PARSE_TIMESTAMP('%FT%H:%M:%E*S%Ez', timestamp) AS timestamp
    ),
    -- logName is projects/<project>/logs/<log id>, the log id URL-encoded.
    REPLACE(REGEXP_EXTRACT(logName, r'/logs/([^/]+)$'), '%2F', '/') AS log_id,
    -- latency is a duration string such as "0.123456789s", and in _AllLogs
    -- a STRUCT of whole seconds and nanos.
    CAST(RTRIM(httpRequest.latency, 's') AS NUMERIC) AS latency_s
  FROM `${staging}`
)
WHERE resource.type IN ('cloud_run_revision', 'cloud_run_job')
  AND log_id IN ('run.googleapis.com/requests', 'run.googleapis.com/stdout', 'run.googleapis.com/stderr')
  AND NOT IFNULL(
    JSON_VALUE(resource.labels.service_name) = '${namespace}-website'
    AND JSON_VALUE(jsonPayload.message) = 'event',
    FALSE
  )
-- A second copy into the same bucket writes each entry again. Cloud Logging
-- treats entries with the same log, insertId and timestamp as one.
QUALIFY ROW_NUMBER() OVER (PARTITION BY logName, insertId, timestamp) = 1
