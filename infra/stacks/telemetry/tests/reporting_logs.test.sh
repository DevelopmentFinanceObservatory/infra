#!/usr/bin/env bash
# Tests the views over logs_daily: sql/reporting/service_requests_daily.sql,
# service_routes_daily.sql, service_errors_daily.sql, mcp_daily.sql,
# website_requests_daily.sql and deploys.sql, against literal rows in
# logs_daily's schemas (sql/logs_daily.sql). Not wired into CI. Run by hand
# after touching any of them:
#   infra/stacks/telemetry/tests/reporting_logs.test.sh [project]
#
# The first five pass their source's columns through, and the test pins
# each one's columns and their order. deploys leaves out the revisions that
# were serving when the logs source began.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"

SOURCES="WITH
  requests_daily AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<day DATE, service STRING, requests INT64, status_4xx INT64,
      status_5xx INT64, latency_p50_ms FLOAT64, latency_p95_ms FLOAT64, latency_p99_ms FLOAT64>>[
    ('2026-10-05', 'dfo-prod-api', 10, 2, 1, 12.5, 80.0, 120.0)])
  ),
  routes_daily AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<day DATE, service STRING, method STRING, route STRING,
      requests INT64, status_4xx INT64, status_5xx INT64, latency_p50_ms FLOAT64,
      latency_p95_ms FLOAT64, latency_p99_ms FLOAT64>>[
    ('2026-10-05', 'dfo-prod-api', 'GET', '/v1/x/:id', 10, 2, 1, 12.5, 80.0, 120.0)])
  ),
  errors_daily AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<day DATE, resource_type STRING, service STRING,
      logger STRING, severity STRING, entries INT64>>[
    ('2026-10-05', 'cloud_run_job', 'dfo-prod-export', NULL, 'ERROR', 3)])
  ),
  mcp_daily AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<day DATE, caller_kind STRING, client STRING,
      request STRING, outcome STRING, calls INT64, callers_sketch BYTES>>[
    ('2026-10-23', 'ip', 'claude-code', 'get_data', 'ok', 16, FROM_BASE64('AQID'))])
  ),
  website_requests_daily AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<day DATE, route STRING, kind STRING, bot BOOL,
      status_class INT64, requests INT64, callers_sketch BYTES>>[
    ('2026-10-24', '/data/:id', 'page', FALSE, 2, 7, FROM_BASE64('AQID')),
    ('2026-10-24', NULL, 'unparsed', NULL, NULL, 3, NULL)])
  ),
  deploys AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<service STRING, revision STRING, first_request TIMESTAMP,
      before_source BOOL>>[
    ('dfo-prod-api', 'dfo-prod-api-00001-abc', '2026-09-23 00:00:01+00', TRUE),
    ('dfo-prod-api', 'dfo-prod-api-00002-def', '2026-10-06 12:00:00+00', FALSE)])
  )"

check service_requests_daily \
    '{"day":"2026-10-05","service":"dfo-prod-api","requests":10,"status_4xx":2,"status_5xx":1,"latency_p50_ms":12.5,"latency_p95_ms":80,"latency_p99_ms":120}' \
    "$(view_rows service_requests_daily 't.day' requests_daily=requests_daily)"

check service_routes_daily \
    '{"day":"2026-10-05","service":"dfo-prod-api","method":"GET","route":"/v1/x/:id","requests":10,"status_4xx":2,"status_5xx":1,"latency_p50_ms":12.5,"latency_p95_ms":80,"latency_p99_ms":120}' \
    "$(view_rows service_routes_daily 't.day' routes_daily=routes_daily)"

check service_errors_daily \
    '{"day":"2026-10-05","resource_type":"cloud_run_job","service":"dfo-prod-export","logger":null,"severity":"ERROR","entries":3}' \
    "$(view_rows service_errors_daily 't.day' errors_daily=errors_daily)"

check mcp_daily \
    '{"day":"2026-10-23","caller_kind":"ip","client":"claude-code","request":"get_data","outcome":"ok","calls":16,"callers_sketch":"AQID"}' \
    "$(view_rows mcp_daily 't.day' mcp_daily=mcp_daily)"

check website_requests_daily \
    '{"day":"2026-10-24","route":null,"kind":"unparsed","bot":null,"status_class":null,"requests":3,"callers_sketch":null}
{"day":"2026-10-24","route":"/data/:id","kind":"page","bot":false,"status_class":2,"requests":7,"callers_sketch":"AQID"}' \
    "$(view_rows website_requests_daily 't.route' website_requests_daily=website_requests_daily)"

# The revision serving when the source began is not a deploy.
check deploys \
    '{"service":"dfo-prod-api","revision":"dfo-prod-api-00002-def","deployed_at":"2026-10-06T12:00:00Z"}' \
    "$(view_rows deploys 't.deployed_at' deploys=deploys)"

finish reporting_logs.test.sh
