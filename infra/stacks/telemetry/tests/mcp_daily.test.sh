#!/usr/bin/env bash
# Tests how sql/parse_mcp_line.sql parses the combined MCP server's log
# lines into mcp_daily, against literal entries in the shapes
# harness.combined_mcp in dfo-ai writes, with made-up callers, through both
# writers: the mcp_daily INSERT of sql/logs_daily.sql, and
# sql/mcp_daily_history.sql, which scripts/load-logs-backfill.sh runs over
# the staged copy, with each of its refusals and those of
# sql/mcp_daily_preflight.sql. The loader's scripts are filled and its report
# read by fill_mcp_sql and mcp_report of scripts/mcp-daily-lib.sh, which the
# loader sources too. Not wired into CI. Run by hand after touching
# any of the four:
#   infra/stacks/telemetry/tests/mcp_daily.test.sh [project]
#
# Each case runs the statements as one BigQuery script, with the function as
# a temp function, the sources replaced by literal entries and mcp_daily by a
# temp table, so the script reads no table and writes nothing. The scheduled
# query's case reads entries from yesterday, with no gap. The loader's case
# reads the same lines as staged LogEntry rows, shaped as
# backfill_entries.test.sh builds them, and as dfo_logs entries, either side
# of the cut-off, and must give the same rows. load_from.test.sh tests the
# scheduled query's window. The project (default prod-fin-observatory) only
# bills and runs the jobs, and the caller needs bigquery.jobs.create on it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"
# shellcheck source=infra/stacks/telemetry/tests/logs-daily-lib.sh
. "$DIR/logs-daily-lib.sh"
# shellcheck source=scripts/mcp-daily-lib.sh
. "$DIR/../../../../scripts/mcp-daily-lib.sh"

# shellcheck disable=SC2016 # the pattern is the template's literal placeholder
MCP="$(statements 'INSERT INTO `[$][{]dataset[}][.]mcp_daily`')"
HISTORY_DECLARES="$(statements 'DECLARE ' mcp_daily_history.sql)"
HISTORY="$(statements '!DECLARE ' mcp_daily_history.sql)"

TAIL='client_version="2.1.309" views=undeclared view_mime_types=None'
CLIENT_64="$(printf 'a%.0s' {1..64})"

# entry <logger> <message> [timestamp]: an stderr entry in the dfo_logs
# columns, from yesterday noon by default. The message holds no single quote.
entry() {
    printf "(%s, 'run.googleapis.com/stderr', 'INFO',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-ai\"}'),
    JSON_OBJECT('logger', '%s', 'message', '%s'))" \
        "${3:-TIMESTAMP(CURRENT_DATE() - 1) + INTERVAL 12 HOUR}" "$1" "$2"
}

# staged <timestamp> <insert id> <logger> <message> [log]: an entry of the
# log, stderr by default, as the loader stages it from the copy, a LogEntry
# with jsonPayload cut to logger and message.
staged() {
    printf "('%s', 'projects/p/logs/run.googleapis.com%%2F%s', '%s', 'INFO',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-ai\"}'),
    NULL, (TO_JSON('%s'), TO_JSON('%s')))" "$1" "${5:-stderr}" "$2" "$3" "$4"
}

LINES="$(
    cat <<EOF
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
)"
OTHER_LOGGER="combined mcp call tool=search outcome=ok revision=2026-07-28 caller=ip:6b1f0c trace_id=e5f6a7 client=\"claude-code\" $TAIL"

ENTRIES="$(
    sep=""
    n=0
    while IFS= read -r line; do
        printf '%s%s' "$sep" "$(entry harness.combined_mcp "$line")"
        sep=",
  "
        n=$((n + 1))
    done <<<"$LINES"
    [ "$n" -gt 0 ] || exit 1
    printf ',\n  %s' "$(entry harness.app "$OTHER_LOGGER")"
)"

SOURCE="(SELECT * FROM UNNEST(ARRAY<STRUCT<
    timestamp TIMESTAMP, log_id STRING, severity STRING,
    resource STRUCT<type STRING, labels JSON>, json_payload JSON>>[
  $ENTRIES]))"
SCRIPT="DECLARE load_from DATE DEFAULT CURRENT_DATE() - 1;
DECLARE gap_start, gap_end DATE DEFAULT CURRENT_DATE() - 30;
$MCP_FUNCTION
CREATE TEMP TABLE mcp_daily (
  day DATE, caller_kind STRING, client STRING, request STRING, outcome STRING, calls INT64,
  callers_sketch BYTES
);
$MCP"
# shellcheck disable=SC2016 # the patterns are the template's literal placeholders
SCRIPT="${SCRIPT//'`${source}`'/$SOURCE}"
# shellcheck disable=SC2016
SCRIPT="${SCRIPT//'`${dataset}.mcp_daily`'/mcp_daily}"
# shellcheck disable=SC2016
SCRIPT="${SCRIPT//'`${parse_mcp_line}`'/parse_mcp_line}"

# Two lines from one caller count once. The line with no caller has no
# sketch. A line in a shape the parser does not know, here with a field
# after trace_id, counts as unparsed with no caller. The warning and the
# line from another logger add nothing.
WANT="$(
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
)"
# day_rows <day>: mcp_daily's rows on <day>, with each sketch's distinct
# callers in place of the sketch, or null for no sketch.
day_rows() {
    script_rows "SELECT TO_JSON_STRING(t) AS row FROM (
  SELECT
    * EXCEPT (day, callers_sketch),
    IF(callers_sketch IS NULL, NULL, HLL_COUNT.EXTRACT(callers_sketch)) AS callers
  FROM mcp_daily
  WHERE day = $1
) AS t
ORDER BY t.caller_kind, t.client, t.request"
}
check rows "$WANT" "$(day_rows 'CURRENT_DATE() - 1')"

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


# The loader's case, at the cut-off 2026-10-23 19:00 UTC, with dfo_logs'
# oldest entry at 18:48:34, as in prod. The second line is in dfo_logs
# after the cut-off, and every other line is staged before it, so the
# cut-off day's rows are the loader's. Each of these adds nothing: the first
# line staged twice by a second copy, the second line staged at the
# cut-off, which dfo_logs holds, the first line in dfo_logs before the
# cut-off, which the copy holds, and on the next day, which the scheduled
# query owns, and the other logger's line. The copy's oldest entry is on
# 2026-10-21, a line that would count if that day were whole, so the
# loader's first whole day is 2026-10-22 and the oldest day adds nothing.
# The first line is staged on 2026-10-22 too, so that day keeps one call.
CUTOFF="2026-10-23 19:00:00+00"
STAGED_LINES="$(
    i=0
    while IFS= read -r line; do
        i=$((i + 1))
        [ "$i" -eq 2 ] && continue
        printf '%s,\n  ' "$(staged 2026-10-23T12:00:00.123456789Z "line-$i" harness.combined_mcp "$line")"
    done <<<"$LINES"
    [ "$i" -gt 2 ] || exit 1
    printf '%s,\n  ' "$(staged 2026-10-23T12:00:00.123456789Z line-1 harness.combined_mcp "$(sed -n 1p <<<"$LINES")")"
    staged 2026-10-23T12:00:01Z other-logger harness.app "$OTHER_LOGGER"
)"
STAGED_LATE="$(staged 2026-10-23T19:00:00Z line-2-late harness.combined_mcp "$(sed -n 2p <<<"$LINES")")"
STAGED_EARLIER="$(
    printf '%s,\n  ' "$(staged 2026-10-21T08:00:00Z oldest-day harness.combined_mcp "$(sed -n 2p <<<"$LINES")")"
    staged 2026-10-22T08:00:00Z day-before harness.combined_mcp "$(sed -n 1p <<<"$LINES")"
)"
STAGED="$STAGED_EARLIER,
  $STAGED_LINES,
  $STAGED_LATE"
LIVE_OLDEST="$(entry harness.combined_mcp "$(sed -n 1p <<<"$LINES")" "TIMESTAMP '2026-10-23 18:48:34+00'")"
LIVE_AFTER="$(
    entry harness.combined_mcp "$(sed -n 2p <<<"$LINES")" "TIMESTAMP '2026-10-23 20:00:00+00'"
    printf ',\n  %s' "$(entry harness.combined_mcp "$(sed -n 1p <<<"$LINES")" "TIMESTAMP '2026-10-24 00:00:00+00'")"
)"
LIVE="$LIVE_OLDEST,
  $LIVE_AFTER"
# The loader's rows from an earlier load, on the day before the cut-off day
# and on the cut-off day, which the run replaces, the row on the copy's
# oldest day, from an earlier and longer copy, which it keeps, and the
# scheduled query's row on the day after, which it keeps.
SEEDS="(DATE '2026-10-21', 'ip', 'earlier', 'earlier', 'ok', 1, NULL),
  (DATE '2026-10-22', 'ip', 'stale', 'stale', 'ok', 1, NULL),
  (DATE '2026-10-23', 'ip', 'stale', 'stale', 'ok', 1, NULL),
  (DATE '2026-10-24', 'ip', 'scheduled', 'get_data', 'ok', 1, NULL)"

# fill_script <script> <live> [tables] [backfill]: <script> through the
# loader's fill_mcp_sql, with the dfo_logs entries <live> as the live source,
# INFORMATION_SCHEMA.TABLES listing <tables>, mcp_daily by default, mcp_daily
# as the temp table, the parse as the temp function, and the cut-off.
fill_script() {
    local tables="${3:-}"
    [ -n "$tables" ] || tables="'mcp_daily'"
    mcp_ref_live="(SELECT * FROM UNNEST(ARRAY<STRUCT<
    timestamp TIMESTAMP, log_id STRING, severity STRING,
    resource STRUCT<type STRING, labels JSON>, json_payload JSON>>[
  $2]))"
    mcp_ref_tables="(SELECT table_name FROM UNNEST([$tables]) AS table_name)"
    mcp_ref_table=mcp_daily
    mcp_ref_parse=parse_mcp_line
    mcp_cutoff="$CUTOFF"
    if [ "$#" -ge 4 ]; then
        fill_mcp_sql "$4" <<<"$1"
    else
        fill_mcp_sql <<<"$1"
    fi
}

# history_script <staged> <live> [seeds]: sql/mcp_daily_history.sql over the
# staged rows <staged> and the dfo_logs entries <live>, with mcp_daily a temp
# table holding <seeds>, SEEDS by default.
history_script() {
    local backfill script
    backfill="$(cat "$DIR/../sql/backfill_entries.sql")"
    # shellcheck disable=SC2016
    backfill="${backfill//'`${staging}`'/(SELECT * FROM UNNEST(ARRAY<STRUCT<
    timestamp STRING, logName STRING, insertId STRING, severity STRING,
    resource STRUCT<type STRING, labels JSON>,
    httpRequest STRUCT<requestMethod STRING, requestUrl STRING, status INT64, latency STRING>,
    jsonPayload STRUCT<logger JSON, message JSON>>>[
  $1]))}"
    # shellcheck disable=SC2016
    backfill="${backfill//'${namespace}'/dfo-prod}"
    script="$HISTORY_DECLARES
$MCP_FUNCTION
CREATE TEMP TABLE mcp_daily (
  day DATE, caller_kind STRING, client STRING, request STRING, outcome STRING, calls INT64,
  callers_sketch BYTES
);
INSERT INTO mcp_daily VALUES
  ${3:-$SEEDS};
$HISTORY"
    fill_script "$script" "$2" "" "$backfill"
}

# preflight_script <live> [tables]: sql/mcp_daily_preflight.sql over the
# dfo_logs entries <live>, with INFORMATION_SCHEMA.TABLES listing <tables>.
preflight_script() {
    fill_script "$(cat "$DIR/../sql/mcp_daily_preflight.sql")" "$1" "${2:-}"
}

# report <script>: the "<day>,<calls>" rows the loader reads from <script>'s
# output, through its mcp_report.
report() {
    mcp_report "$(bq --quiet query --project_id="$PROJECT" --location=EU --use_legacy_sql=false \
        --format=csv --max_rows=1000 <<<"$1")"
}

# refuses <name> <code> <script>: <script> fails with the refusal
# mcp_history:<code>: and no other. With an empty <code>, it runs.
refuses() {
    local out got want="mcp_history:$2:"
    [ -n "$2" ] || want="the script ran"
    if out="$(bq --quiet query --project_id="$PROJECT" --location=EU --use_legacy_sql=false \
        --format=csv <<<"$3" 2>&1)"; then
        got="the script ran"
    else
        got="$(grep -o 'mcp_history:[a-z_]*:' <<<"$out" | head -1 || true)"
    fi
    check "$1" "$want" "${got:-no refusal code in: $out}"
}

SCRIPT="$(history_script "$STAGED" "$LIVE")"
check history-rows "$WANT" "$(day_rows "DATE '2026-10-23'")"
# Every row off the cut-off day. The earlier copy's row on the oldest day and
# the scheduled query's row on the day after stay as seeded, and the stale
# row on the day before gives way to the staged line's. A line dfo_logs
# holds after the cut-off day or the staged copy holds on its oldest day
# would add a row.
OTHER_DAYS_WANT="$(
    cat <<EOT
2026-10-21 earlier 1
2026-10-22 claude-code 1
2026-10-24 scheduled 1
EOT
)"
other_days() {
    script_rows "SELECT FORMAT('%t %s %d', day, client, calls) AS row
FROM mcp_daily
WHERE day != DATE '2026-10-23'
ORDER BY day, client"
}
check history-other-days "$OTHER_DAYS_WANT" "$(other_days)"
# The script's report covers the range it replaced and carries the marker,
# and no other statement's rows do.
check history-report "$(
    cat <<EOT
2026-10-22,1
2026-10-23,11
EOT
)" "$(report "$SCRIPT")"

# The copy's requests folder starts on 2026-10-20, a day before its stderr
# folder, where the parse reads. The range still starts after the oldest
# stderr entry's day, so the seeded row of 2026-10-21 stays and the days are
# the same as without that entry.
SCRIPT="$(history_script "$STAGED,
  $(staged 2026-10-20T08:00:00Z requests-first harness.app "$OTHER_LOGGER" requests)" "$LIVE")"
check history-requests-start-earlier "$OTHER_DAYS_WANT" "$(other_days)"

# A copy that stops at 18:55, after dfo_logs' oldest entry, loads, and a line
# dfo_logs holds between 18:55 and the cut-off goes uncounted, since the
# script assumes the copy runs to the cut-off. The line staged at 18:55
# counts.
SHORT_STAGED="$STAGED_EARLIER,
  $STAGED_LINES,
  $(staged 2026-10-23T18:55:00Z line-1-1855 harness.combined_mcp "$(sed -n 1p <<<"$LINES")")"
SHORT_LIVE="$LIVE,
  $(entry harness.combined_mcp "$(sed -n 1p <<<"$LINES")" "TIMESTAMP '2026-10-23 18:57:00+00'")"
check history-copy-ends-at-1855 "$(
    cat <<EOT
2026-10-22,1
2026-10-23,12
EOT
)" "$(report "$(history_script "$SHORT_STAGED" "$SHORT_LIVE")")"

# Each refusal, by its code.
# The preflight passes with mcp_daily listed and dfo_logs reaching the
# cut-off, and refuses on either alone.
refuses preflight-passes "" "$(preflight_script "$LIVE")"
refuses preflight-no-mcp-daily no_mcp_daily "$(preflight_script "$LIVE" "'requests_daily'")"
refuses preflight-dfo-logs-after-cutoff dfo_logs_after_cutoff "$(preflight_script "$LIVE_AFTER")"
refuses history-dfo-logs-after-cutoff dfo_logs_after_cutoff "$(history_script "$STAGED" "$LIVE_AFTER")"
refuses history-copy-after-cutoff copy_after_cutoff "$(history_script "$STAGED_LATE" "$LIVE")"
refuses history-no-whole-day no_whole_day "$(history_script "$STAGED_LINES,
  $STAGED_LATE" "$LIVE")"
# A copy that ends at 18:40, before dfo_logs' oldest entry.
refuses history-copy-ends-early copy_ends_early "$(history_script "$STAGED_EARLIER,
  $(staged 2026-10-23T18:40:00Z line-1-1840 harness.combined_mcp "$(sed -n 1p <<<"$LINES")")" "$LIVE")"
# No staged line comes from the combined MCP server, while dfo_logs still
# holds its lines after the cut-off, which the check must not count. The
# replacement touches the staged entries only, so the parse still looks for
# harness.combined_mcp.
refuses history-no-mcp-call no_mcp_call "$(history_script "${STAGED//harness.combined_mcp/harness.app}" "$LIVE")"
# The earlier load's row holds more calls on the cut-off day than the copy
# yields.
refuses history-fewer-calls fewer_calls "$(history_script "$STAGED" "$LIVE" \
    "(DATE '2026-10-23', 'ip', 'stale', 'stale', 'ok', 1000, NULL)")"

finish mcp_daily.test.sh
