#!/usr/bin/env bash
# Tests how sql/logs_daily.sql turns the website's request lines into
# website_requests_daily, against literal entries in the shapes
# src/lib/proxy/requestLog.ts in dfo-website writes, with made-up callers.
# Not wired into CI. Run by hand after touching the website_requests_daily
# statement:
#   infra/stacks/telemetry/tests/website_requests_daily.test.sh [project]
#
# The case runs the website_requests_daily INSERT as one BigQuery script,
# with ${source} replaced by literal entries from yesterday, no gap,
# normalise_route by a temp function with the body of
# sql/normalise_route.sql, and the table by a temp table, so the script reads
# no table and writes nothing.
# load_from.test.sh tests the window. The project (default
# prod-fin-observatory) only bills and runs the jobs, and the caller needs
# bigquery.jobs.create on it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"
# shellcheck source=infra/stacks/telemetry/tests/logs-daily-lib.sh
. "$DIR/logs-daily-lib.sh"

# shellcheck disable=SC2016 # the pattern is the template's literal placeholder
WEB="$(statements 'INSERT INTO `[$][{]dataset[}][.]website_requests_daily`')"
ROUTE_BODY="$(cat "$DIR/../sql/normalise_route.sql")"

# entry <service> <log id> <payload>: an entry from yesterday noon. The
# payload is JSON that holds no single quote.
entry() {
    printf "(TIMESTAMP(CURRENT_DATE() - 1) + INTERVAL 12 HOUR, 'run.googleapis.com/%s', 'INFO',
    ('cloud_run_revision', JSON '{\"service_name\": \"%s\"}'),
    PARSE_JSON('%s'))" "$2" "$1" "$3"
}

# The website's lines, in the shape the producer writes. The callers ip:aa
# to ip:dd each stand for one visitor.
ENTRIES="$(
    sep=""
    while IFS= read -r payload; do
        printf '%s%s' "$sep" "$(entry dfo-prod-website stdout "$payload")"
        sep=",
  "
    done <<'LINES'
{"message":"request","caller":"ip:aa","method":"GET","path":"/studio/12345","host":"h","kind":"page","status":200,"bot":false}
{"message":"request","caller":"ip:aa","method":"GET","path":"/studio/67890","host":"h","kind":"page","status":200,"bot":false}
{"message":"request","caller":"ip:bb","method":"GET","path":"/about","host":"h","kind":"page","status":200,"bot":false}
{"message":"request","caller":"ip:dd","method":"GET","path":"/about","host":"h","kind":"page","status":100,"bot":true}
{"message":"request","caller":"ip:bb","method":"GET","path":"/about","host":"h","kind":"rsc","status":304,"bot":false}
{"message":"request","caller":"ip:cc","method":"GET","path":"/about","host":"h","kind":"prefetch","status":599,"bot":false}
{"message":"request","caller":"ip:aa","method":"GET","path":"/api/v1/search","host":"h","kind":"api","status":200,"bot":false}
{"message":"request","caller":null,"method":"GET","path":"/api/x","host":"h","kind":"api","status":404,"bot":true}
{"message":"request","method":"GET","path":"/api/x","host":"h","kind":"api","status":404,"bot":true}
{"message":"request","caller":"ip:e1","method":"GET","path":"/about","host":"h","kind":"page","bot":false}
{"message":"request","caller":"ip:e2","method":"GET","path":"/about","host":"h","kind":"page","status":200}
{"message":"request","caller":"ip:e3","method":"GET","path":"/about","host":"h","kind":"page","status":99,"bot":false}
{"message":"request","caller":"ip:e4","method":"GET","path":"/about","host":"h","kind":"page","status":600,"bot":false}
{"message":"request","caller":"ip:e5","method":"GET","path":"/about","host":"h","kind":"page","status":"200","bot":false}
{"message":"request","caller":"ip:e6","method":"GET","path":"/about","host":"h","kind":"page","status":200.5,"bot":false}
{"message":"request","caller":"ip:e7","method":"GET","path":"/about","host":"h","kind":"asset","status":200,"bot":false}
{"message":"request","caller":"ip:e8","method":"GET","path":"/about","host":"h","status":200,"bot":false}
{"message":"request","caller":"ip:e9","method":"GET","path":"/about","host":"h","kind":"page","status":200,"bot":"false"}
{"message":"event","caller":"ip:f1","method":"GET","path":"/about","host":"h","kind":"page","status":200,"bot":false}
LINES
    printf ',\n  %s' "$(entry dfo-prod-apis stdout '{"message":"request","caller":"ip:f2","kind":"page","status":200,"bot":false}')"
    printf ',\n  %s' "$(entry dfo-prod-website stderr '{"message":"request","caller":"ip:f3","kind":"page","status":200,"bot":false}')"
)"

SOURCE="(SELECT * FROM UNNEST(ARRAY<STRUCT<
    timestamp TIMESTAMP, log_id STRING, severity STRING,
    resource STRUCT<type STRING, labels JSON>, json_payload JSON>>[
  $ENTRIES]))"
SCRIPT="DECLARE load_from DATE DEFAULT CURRENT_DATE() - 1;
DECLARE gap_start, gap_end DATE DEFAULT CURRENT_DATE() - 30;
CREATE TEMP FUNCTION normalise_route(url STRING) RETURNS STRING AS (
$ROUTE_BODY
);
CREATE TEMP TABLE website_requests_daily (
  day DATE, route STRING, kind STRING, bot BOOL, status_class INT64, requests INT64,
  callers_sketch BYTES
);
$WEB"
# shellcheck disable=SC2016 # the patterns are the template's literal placeholders
SCRIPT="${SCRIPT//'`${source}`'/$SOURCE}"
# shellcheck disable=SC2016
SCRIPT="${SCRIPT//'`${dataset}.website_requests_daily`'/website_requests_daily}"
# shellcheck disable=SC2016
SCRIPT="${SCRIPT//'`${normalise_route}`'/normalise_route}"
# shellcheck disable=SC2016
SCRIPT="${SCRIPT//'${website_service}'/dfo-prod-website}"

# Each row, with its sketch's distinct callers in place of the sketch, or
# null for no sketch.
# The four kinds parse with their status class and bot verdict, including
# statuses 100 and 599. Two lines from one caller count once, and the two
# lines with no caller leave the sketch null. Nine lines each break one rule
# (no status, no bot, status 99, status 600, a string status, a fractional
# status, a kind outside the four, no kind, a string bot) and make one
# unparsed row with no route, bot or status class, and no sketch. The event
# line, the other service's line and the stderr line add nothing.
check rows "$(
    cat <<EOF
{"route":"/api/v1/search","kind":"api","bot":false,"status_class":2,"requests":1,"callers":1}
{"route":"/api/x","kind":"api","bot":true,"status_class":4,"requests":2,"callers":null}
{"route":"/about","kind":"page","bot":false,"status_class":2,"requests":1,"callers":1}
{"route":"/about","kind":"page","bot":true,"status_class":1,"requests":1,"callers":1}
{"route":"/studio/:id","kind":"page","bot":false,"status_class":2,"requests":2,"callers":1}
{"route":"/about","kind":"prefetch","bot":false,"status_class":5,"requests":1,"callers":1}
{"route":"/about","kind":"rsc","bot":false,"status_class":3,"requests":1,"callers":1}
{"route":null,"kind":"unparsed","bot":null,"status_class":null,"requests":9,"callers":null}
EOF
)" "$(script_rows "SELECT TO_JSON_STRING(t) AS row FROM (
  SELECT
    * EXCEPT (day, callers_sketch),
    IF(callers_sketch IS NULL, NULL, HLL_COUNT.EXTRACT(callers_sketch)) AS callers
  FROM website_requests_daily
  WHERE day = CURRENT_DATE() - 1
) AS t
ORDER BY t.kind, t.route, t.bot, t.status_class")"

# The sketches of all rows merge to the four callers that made a parsed
# request, though ip:aa and ip:bb appear in several rows. The callers of the
# unparsed lines are not in it.
check merged '{"callers":4}' "$(script_rows "SELECT TO_JSON_STRING(t) AS row FROM (
  SELECT HLL_COUNT.MERGE(callers_sketch) AS callers FROM website_requests_daily
) AS t")"

finish website_requests_daily.test.sh
