-- The view logs_daily.entries, a Terraform template (logs_daily.tf), which
-- logs_daily.sql reads as its source. It holds the columns logs_daily.sql
-- reads from two sources split at the cut-off ${cutoff}: ${logs}, the linked
-- dataset's view of every entry the telemetry sink routes, from the cut-off
-- on, and ${backfill}, the entries copied from _Default, before it. The sink's
-- first entry is at 18:48:34 UTC, but it routed every entry only from about
-- 18:50, so the cut-off sits at 19:00 and the copy reaches it. No entry appears twice
-- and none is missing.
SELECT
  timestamp,
  log_id,
  severity,
  resource,
  IF(
    http_request IS NULL,
    NULL,
    STRUCT(
      http_request.request_method AS request_method,
      http_request.request_url AS request_url,
      http_request.status AS status,
      http_request.latency AS latency
    )
  ) AS http_request,
  json_payload
FROM `${logs}`
WHERE timestamp >= TIMESTAMP '${cutoff}'
UNION ALL
SELECT timestamp, log_id, severity, resource, http_request, json_payload
FROM `${backfill}`
WHERE timestamp < TIMESTAMP '${cutoff}'
