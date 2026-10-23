#!/usr/bin/env bash
# Tests the window sql/logs_daily.sql loads against literal sources: the
# start day it computes, load_from, and the end of its source reads before
# the current UTC day. Not wired into CI. Run by hand after touching the
# DECLARE and SET statements at the top of the query or the source reads of
# requests_daily, routes_daily, errors_daily and mcp_daily:
#   infra/stacks/telemetry/tests/load_from.test.sh [project]
#
# Each case runs some of the query's statements as one BigQuery script, with
# ${source}, ${live_source} and the tables replaced by literal arrays or temp
# tables, so the script reads no table and writes nothing. The project
# (default prod-fin-observatory) only bills and runs the jobs, and the caller
# needs bigquery.jobs.create on it.
set -euo pipefail

PROJECT="${1:-prod-fin-observatory}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUTOFF="2026-10-23 19:00:00+00"

# shellcheck source=infra/stacks/telemetry/tests/logs-daily-lib.sh
. "$DIR/logs-daily-lib.sh"

HEAD="$(statements 'DECLARE |SET ')"

timestamps() { echo "(SELECT timestamp FROM UNNEST(ARRAY<TIMESTAMP>[$1]) AS timestamp)"; }
days() { echo "(SELECT day FROM UNNEST(ARRAY<DATE>[$1]) AS day)"; }

failures=0
cases=0
# check <name> <source timestamps> <live_source timestamps> <requests_daily days> <want>
check() {
    local script
    script="$HEAD"
    # shellcheck disable=SC2016 # the patterns are the template's literal placeholders
    script="${script//'`${source}`'/$(timestamps "$2")}"
    # shellcheck disable=SC2016
    script="${script//'`${live_source}`'/$(timestamps "$3")}"
    # shellcheck disable=SC2016
    script="${script//'`${dataset}.requests_daily`'/$(days "$4")}"
    # shellcheck disable=SC2016
    script="${script//'${cutoff}'/$CUTOFF}"
    script="$script
SELECT IFNULL(CAST(load_from AS STRING), 'NULL') AS load_from;"
    local got
    got="$(bq --quiet query --project_id="$PROJECT" --location=EU --use_legacy_sql=false \
        --format=csv <<<"$script" | tail -n 1)"
    cases=$((cases + 1))
    if [ "$got" != "$5" ]; then
        echo "FAIL $1: want $5, got $got" >&2
        failures=$((failures + 1))
    fi
}

BACKFILL="TIMESTAMP '2026-09-23 10:00:00+00', TIMESTAMP '2026-10-23 18:59:00+00'"
LIVE="TIMESTAMP '2026-10-23 18:48:34+00', TIMESTAMP '2026-11-10 12:00:00+00'"

# With no source, nothing loads.
check empty-source "" "" "" NULL
# dfo_logs reaches the cut-off.
check contiguous-empty-table "$BACKFILL" "$LIVE" "" 2026-09-24
check contiguous-daily "$BACKFILL" "$LIVE" "DATE '2026-11-10'" 2026-11-09
check contiguous-floor "$BACKFILL" "$LIVE" "DATE '2026-09-24'" 2026-09-24
# With dfo_logs empty there is nothing to reload, so nothing is deleted.
check live-empty "$BACKFILL" "" "DATE '2026-10-01'" NULL
# Retention has moved dfo_logs' oldest entry past the cut-off.
check gap-outage "$BACKFILL" "TIMESTAMP '2026-12-05 03:00:00+00'" "DATE '2026-11-01'" 2026-12-06
check gap-daily "$BACKFILL" "TIMESTAMP '2026-12-05 03:00:00+00'" "DATE '2026-12-30'" 2026-12-29
check gap-empty-table "$BACKFILL" "TIMESTAMP '2026-12-05 03:00:00+00'" "" 2026-09-24
check gap-on-cutoff-day "$BACKFILL" "TIMESTAMP '2026-10-23 20:00:00+00'" "DATE '2026-10-24'" 2026-10-24

# The source reads of requests_daily, errors_daily and mcp_daily, run from
# load_from yesterday over a request, an error and an MCP entry just before
# midnight and just after it. The run's own day is partial, so only yesterday's entries load.
# routes_daily reads the requests temp table, so it shares that bound.
REQUESTS="$(statements 'CREATE TEMP TABLE requests ')"
# shellcheck disable=SC2016 # the pattern is the template's literal placeholder
ERRORS="$(statements 'INSERT INTO `[$][{]dataset[}][.]errors_daily`')"
MCP_LINE="$(statements 'DECLARE mcp_line ')"
# shellcheck disable=SC2016 # the pattern is the template's literal placeholder
MCP="$(statements 'INSERT INTO `[$][{]dataset[}][.]mcp_daily`')"
# A tool call as harness.combined_mcp logs it.
MCP_ENTRY='combined mcp call tool=get_data outcome=ok revision=2026-07-28 caller=ip:0f3a trace_id=None client="claude-code" client_version="2.1.309" views=undeclared view_mime_types=None'
ENTRIES="(SELECT * FROM UNNEST(ARRAY<STRUCT<
    timestamp TIMESTAMP, log_id STRING, severity STRING,
    resource STRUCT<type STRING, labels JSON>,
    http_request STRUCT<request_method STRING, request_url STRING, status INT64,
      latency STRUCT<seconds INT64, nanos INT64>>,
    json_payload JSON>>[
  (TIMESTAMP(CURRENT_DATE()) - INTERVAL 1 SECOND, 'run.googleapis.com/requests', 'INFO',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-api\"}'),
    ('GET', 'https://api.example.org/', 200, (0, 5000000)), NULL),
  (TIMESTAMP(CURRENT_DATE()), 'run.googleapis.com/requests', 'INFO',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-api\"}'),
    ('GET', 'https://api.example.org/', 200, (0, 5000000)), NULL),
  (TIMESTAMP(CURRENT_DATE()) - INTERVAL 1 SECOND, 'run.googleapis.com/stderr', 'ERROR',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-api\"}'),
    NULL, JSON '{\"logger\": \"app\"}'),
  (TIMESTAMP(CURRENT_DATE()), 'run.googleapis.com/stderr', 'ERROR',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-api\"}'),
    NULL, JSON '{\"logger\": \"app\"}'),
  (TIMESTAMP(CURRENT_DATE()) - INTERVAL 1 SECOND, 'run.googleapis.com/stderr', 'INFO',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-ai\"}'),
    NULL, JSON_OBJECT('logger', 'harness.combined_mcp', 'message', '$MCP_ENTRY')),
  (TIMESTAMP(CURRENT_DATE()), 'run.googleapis.com/stderr', 'INFO',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-ai\"}'),
    NULL, JSON_OBJECT('logger', 'harness.combined_mcp', 'message', '$MCP_ENTRY'))]))"
script="DECLARE load_from DATE DEFAULT CURRENT_DATE() - 1;
$MCP_LINE
CREATE TEMP FUNCTION normalise_route(url STRING) AS (url);
CREATE TEMP TABLE errors_daily (
  day DATE, resource_type STRING, service STRING, logger STRING, severity STRING, entries INT64
);
CREATE TEMP TABLE mcp_daily (
  day DATE, caller_kind STRING, client STRING, request STRING, outcome STRING, calls INT64,
  callers_sketch BYTES
);
$REQUESTS
$ERRORS
$MCP
SELECT FORMAT(
  'requests %s and errors %s and mcp %s',
  (SELECT STRING_AGG(CAST(day AS STRING), ' ' ORDER BY day) FROM requests),
  (SELECT STRING_AGG(CAST(day AS STRING), ' ' ORDER BY day) FROM errors_daily),
  (SELECT STRING_AGG(CAST(day AS STRING), ' ' ORDER BY day) FROM mcp_daily)
) AS days;"
# shellcheck disable=SC2016 # the patterns are the template's literal placeholders
script="${script//'`${source}`'/$ENTRIES}"
# shellcheck disable=SC2016
script="${script//'`${normalise_route}`'/normalise_route}"
# shellcheck disable=SC2016
script="${script//'`${dataset}.errors_daily`'/errors_daily}"
# shellcheck disable=SC2016
script="${script//'`${dataset}.mcp_daily`'/mcp_daily}"
got="$(bq --quiet query --project_id="$PROJECT" --location=EU --use_legacy_sql=false \
    --format=csv <<<"$script" | tail -n 1)"
yesterday="$(date -u -v-1d +%F 2>/dev/null || date -u -d '1 day ago' +%F)"
want="requests $yesterday and errors $yesterday and mcp $yesterday"
cases=$((cases + 1))
if [ "$got" != "$want" ]; then
    echo "FAIL whole-days: want $want, got $got" >&2
    failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
    echo "load_from.test.sh: $failures of $cases cases failed" >&2
    exit 1
fi
echo "load_from.test.sh: $cases cases passed"
