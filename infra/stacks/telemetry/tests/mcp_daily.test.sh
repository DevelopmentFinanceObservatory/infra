#!/usr/bin/env bash
# Tests how sql/logs_daily.sql parses the combined MCP server's log lines
# into mcp_daily, against literal entries in the shapes harness.combined_mcp
# in dfo-ai writes, with made-up callers. Not wired into CI. Run by hand
# after touching mcp_line or the mcp_daily statements:
#   infra/stacks/telemetry/tests/mcp_daily.test.sh [project]
#
# The case runs mcp_line and the mcp_daily INSERT as one BigQuery script,
# with ${source} replaced by literal entries from yesterday, no gap, and
# mcp_daily by a temp table, so the script reads no table and writes nothing.
# load_from.test.sh tests the window. The project (default
# prod-fin-observatory) only bills and runs the jobs, and the caller needs
# bigquery.jobs.create on it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"
# shellcheck source=infra/stacks/telemetry/tests/logs-daily-lib.sh
. "$DIR/logs-daily-lib.sh"

MCP_LINE="$(statements 'DECLARE mcp_line ')"
# shellcheck disable=SC2016 # the pattern is the template's literal placeholder
MCP="$(statements 'INSERT INTO `[$][{]dataset[}][.]mcp_daily`')"

TAIL='client_version="2.1.309" views=undeclared view_mime_types=None'
CLIENT_64="$(printf 'a%.0s' {1..64})"

# entry <logger> <message>: an stderr entry from yesterday noon. The message
# holds no single quote.
entry() {
    printf "(TIMESTAMP(CURRENT_DATE() - 1) + INTERVAL 12 HOUR, 'run.googleapis.com/stderr', 'INFO',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-ai\"}'),
    JSON_OBJECT('logger', '%s', 'message', '%s'))" "$1" "$2"
}

ENTRIES="$(
    sep=""
    while IFS= read -r line; do
        printf '%s%s' "$sep" "$(entry harness.combined_mcp "$line")"
        sep=",
  "
    done <<EOF
combined mcp call tool=get_data outcome=ok revision=2026-07-28 caller=ip:6b1f0c trace_id=4bf92f client="claude-code" $TAIL
combined mcp call tool=get_data outcome=ok revision=2026-07-28 caller=ip:6b1f0c trace_id=00f067 client="claude-code" $TAIL
combined mcp call tool=aggregate outcome=operation_still_processing revision=2026-07-28 caller=ip:6b1f0c trace_id=00f068 client="claude-code" $TAIL
combined mcp call resource outcome=ok revision=2026-07-28 caller=user:9d2e41 trace_id=a3ce92 client="Anthropic/ClaudeAI" client_version="1.0.0" views=declared view_mime_types=["text/html;profile=mcp-app"] uri="dfo://artifact/x"
combined mcp call resource_list outcome=ToolError revision=2026-07-28 caller=key:51c7aa trace_id=b7ad6b client="Anthropic/ClaudeAI" client_version="1.0.0" views=declared view_mime_types=None
combined mcp initialize outcome=ok revision=2026-07-28 caller=conversation:e2f7a9 client=None client_version=None views=undeclared view_mime_types=None
combined mcp call tool=search outcome=ok revision=None caller=None trace_id=None client=None client_version=None views=undeclared view_mime_types=None
combined mcp call tool="get data" outcome=bad outcome revision=2026-07-28 caller=user:7c 1a trace_id=c1d2e3 client="claude<code>" $TAIL
combined mcp call tool=search outcome=ok revision=2026-07-28 caller=anon:0a0b trace_id=d4e5f6 client="$CLIENT_64" $TAIL
combined mcp call tool=search outcome=ok revision=2026-07-28 caller=anon:0a0b trace_id=d4e5f7 client="${CLIENT_64}a" $TAIL
combined mcp call tool=get_data outcome=ok revision=2026-07-28 caller=ip:6b1f0c trace_id=f00d01 session=7d client="claude-code" $TAIL
combined mcp: tool get_data stopped at the 60s call limit
EOF
    printf ',\n  %s' "$(entry harness.app "combined mcp call tool=search outcome=ok revision=2026-07-28 caller=ip:6b1f0c trace_id=e5f6a7 client=\"claude-code\" $TAIL")"
)"

SOURCE="(SELECT * FROM UNNEST(ARRAY<STRUCT<
    timestamp TIMESTAMP, log_id STRING, severity STRING,
    resource STRUCT<type STRING, labels JSON>, json_payload JSON>>[
  $ENTRIES]))"
SCRIPT="DECLARE load_from DATE DEFAULT CURRENT_DATE() - 1;
DECLARE gap_start, gap_end DATE DEFAULT CURRENT_DATE() - 30;
$MCP_LINE
CREATE TEMP TABLE mcp_daily (
  day DATE, caller_kind STRING, client STRING, request STRING, outcome STRING, calls INT64,
  callers_sketch BYTES
);
$MCP"
# shellcheck disable=SC2016 # the patterns are the template's literal placeholders
SCRIPT="${SCRIPT//'`${source}`'/$SOURCE}"
# shellcheck disable=SC2016
SCRIPT="${SCRIPT//'`${dataset}.mcp_daily`'/mcp_daily}"

# script_rows <query>: runs $SCRIPT and then <query>, whose one column is a
# JSON row named row, and prints each row. bq prints each statement of a
# script and its result, so the rows are those after the last header.
script_rows() {
    bq --quiet query --project_id="$PROJECT" --location=EU --use_legacy_sql=false \
        --format=csv --max_rows=1000 <<<"$SCRIPT
$1" | awk '$0 == "row" { n = 0; next } { rows[++n] = $0 } END { for (i = 1; i <= n; i++) print rows[i] }' |
        sed 's/^"//;s/"$//;s/""/"/g'
}

# Each row, with its sketch's distinct callers in place of the sketch, or
# null for no sketch.
# Two lines from one caller count once. The line with no caller has no
# sketch. A line in a shape the parser does not know, here with a field
# after trace_id, counts as unparsed with no caller. The warning and the
# line from another logger add nothing.
check rows "$(
    cat <<EOF
{"caller_kind":"conversation","client":"none","request":"initialize","outcome":"ok","calls":1,"callers":1}
{"caller_kind":"ip","client":"claude-code","request":"aggregate","outcome":"operation_still_processing","calls":1,"callers":1}
{"caller_kind":"ip","client":"claude-code","request":"get_data","outcome":"ok","calls":2,"callers":1}
{"caller_kind":"key","client":"Anthropic/ClaudeAI","request":"resource_list","outcome":"ToolError","calls":1,"callers":1}
{"caller_kind":"none","client":"none","request":"search","outcome":"ok","calls":1,"callers":null}
{"caller_kind":"none","client":"none","request":"unparsed","outcome":"none","calls":1,"callers":null}
{"caller_kind":"other","client":"$CLIENT_64","request":"search","outcome":"ok","calls":1,"callers":1}
{"caller_kind":"other","client":"other","request":"search","outcome":"ok","calls":1,"callers":1}
{"caller_kind":"user","client":"Anthropic/ClaudeAI","request":"resource","outcome":"ok","calls":1,"callers":1}
{"caller_kind":"user","client":"other","request":"other","outcome":"other","calls":1,"callers":1}
EOF
)" "$(script_rows "SELECT TO_JSON_STRING(t) AS row FROM (
  SELECT
    * EXCEPT (day, callers_sketch),
    IF(callers_sketch IS NULL, NULL, HLL_COUNT.EXTRACT(callers_sketch)) AS callers
  FROM mcp_daily
  WHERE day = CURRENT_DATE() - 1
) AS t
ORDER BY t.caller_kind, t.client, t.request")"

# The ip caller's two rows merge to one caller, and the two user callers'
# rows to two. A merge of NULL sketches counts no caller.
check merged "$(
    cat <<EOF
{"caller_kind":"conversation","callers":1}
{"caller_kind":"ip","callers":1}
{"caller_kind":"key","callers":1}
{"caller_kind":"none","callers":0}
{"caller_kind":"other","callers":1}
{"caller_kind":"user","callers":2}
EOF
)" "$(script_rows "SELECT TO_JSON_STRING(t) AS row FROM (
  SELECT caller_kind, HLL_COUNT.MERGE(callers_sketch) AS callers
  FROM mcp_daily
  GROUP BY caller_kind
) AS t
ORDER BY t.caller_kind")"

finish mcp_daily.test.sh
