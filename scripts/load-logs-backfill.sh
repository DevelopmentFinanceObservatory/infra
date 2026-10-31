#!/usr/bin/env bash
# Load the Cloud Run entries `gcloud logging copy` wrote to <bucket> into
# <project>'s logs_daily.backfill_entries, the table the logs_daily.entries
# view reads before its cut-off.
#
# It refuses to run when none of the three folders it loads, named below,
# holds a .json object, when no CopyLogEntries operation into <bucket> is on
# record, and when any of them has not succeeded, since a running, failed or
# cancelled copy leaves days part-written. Several copies into <bucket> are
# fine, since the load drops entries copied twice. --ignore-operation=<id>
# leaves out one operation, by the last segment of its name, for a cancelled
# copy whose range a later succeeded copy repeats. It can be given more than
# once. --skip-copy-check skips the operation check, for copies whose records
# have expired.
#
# The copied files are LogEntry JSON, one entry per line, under a folder per
# log id. The script loads <bucket>/run.googleapis.com/{requests,stdout,stderr}
# into logs_daily.backfill_staging and leaves the other folders alone. It keeps
# only the fields infra/stacks/telemetry/sql/backfill_entries.sql reads, then
# replaces every row of backfill_entries with that query's output in one MERGE,
# so a rerun replaces the previous load. Of jsonPayload, staging keeps logger
# and message, and so no other payload field, such as the website usage events'
# props, reaches BigQuery. Staging holds message text, so it expires after a
# day and the script deletes it on exit. It prints the entries kept per UTC day.
#
# backfill_entries holds no message text, so mcp_daily's days through the
# cut-off day come from this script, and a rebuild of them needs it run again
# over a kept copy. It reads the cut-off from
# infra/stacks/telemetry/logs_backfill_cutoff.txt, the file Terraform reads,
# with its surrounding whitespace trimmed as Terraform's trimspace does.
# The "Backfill" section of infra/dfo-prod/telemetry/README.md says why, what
# the step writes, and what it assumes about the copy. Before it loads staging
# the script runs infra/stacks/telemetry/sql/mcp_daily_preflight.sql. Once
# staging is loaded it runs infra/stacks/telemetry/sql/mcp_daily_history.sql
# before the MERGE and prints the MCP calls it wrote per UTC day. The header
# of mcp_daily_history.sql lists what the two refuse, each refusal with a code
# mcp_history:<code>:. A refusal inside the step leaves backfill_entries and
# mcp_daily as they were. Any other failure of the step's bq call leaves
# mcp_daily as it was unless the transaction committed before the error, in
# which case its days were replaced; either way backfill_entries was not
# replaced and the script exits 1 saying the step failed. A step that commits
# but whose report cannot be read leaves mcp_daily written and
# backfill_entries as it was, and the script exits 1 saying so. The step's
# temp tables hold MCP lines with their callers; the script drops them when it
# succeeds, and a failed run's expire with the script's session within 24
# hours.
#
# Before any write the script also refuses, for the step, a copy with no
# stderr folder, where the combined MCP server logs its call lines, and a
# deployed <namespace>-logs-daily scheduled query that does not call
# logs_daily.parse_mcp_line or does not hold the cut-off as
# TIMESTAMP '<cut-off>', so that the two writers cannot disagree on the
# boundary. That call arrives with the apply that keeps the query's mcp_daily
# DELETE after the cut-off day, and an older query's next run would delete the
# step's days. --skip-mcp-daily leaves out the step and
# these checks and replaces backfill_entries alone, for a copy the step
# refuses.
#
# This script and the scheduled query run DML on mcp_daily, so they do not run
# at the same time. Do not run this script around 02:00 UTC, when the scheduled
# query runs, or during a manual run of it.
#
# The caller needs bigquery.tables.create, getData, updateData and delete on
# logs_daily, bigquery.tables.list and bigquery.tables.get on logs_daily (the
# step reads logs_daily.INFORMATION_SCHEMA.TABLES), bigquery.routines.get on
# logs_daily (the step calls logs_daily.parse_mcp_line),
# bigquery.tables.getData on dfo_logs, bigquery.jobs.create and bigquery.transfers.get on <project>,
# storage.objects.list and get on <bucket>, and logging.operations.list on
# <project>.
#
# Usage: scripts/load-logs-backfill.sh [--ignore-operation=<id>]... [--skip-copy-check] [--skip-mcp-daily] <project> <namespace> <bucket>
#   scripts/load-logs-backfill.sh example-project dfo-prod gs://example-project-logs-backfill
set -euo pipefail

print_usage() {
    sed -n '/^# Usage:/,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
}

skip_copy_check=""
skip_mcp_daily=""
ignored='[]'
args=()
for arg in "$@"; do
    case "$arg" in
    -h | --help)
        print_usage
        exit 0
        ;;
    --skip-copy-check) skip_copy_check=1 ;;
    --skip-mcp-daily) skip_mcp_daily=1 ;;
    --ignore-operation=?*) ignored="$(jq -c --arg id "${arg#--ignore-operation=}" '. + [$id]' <<<"$ignored")" ;;
    -*)
        echo "Unrecognized option: $arg" >&2
        print_usage >&2
        exit 1
        ;;
    *) args+=("$arg") ;;
    esac
done
if [ "${#args[@]}" -ne 3 ] || [ -z "${args[0]}" ] || [ -z "${args[1]}" ] || [ -z "${args[2]}" ]; then
    echo "Expected 3 non-empty arguments: project namespace bucket." >&2
    print_usage >&2
    exit 1
fi

project="${args[0]}"
namespace="${args[1]}"
bucket="${args[2]%/}"
case "$bucket" in
gs://*) ;;
*)
    echo "The bucket must be a gs:// URL: $bucket" >&2
    exit 1
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stack="$repo_root/infra/stacks/telemetry"
# shellcheck source=scripts/mcp-daily-lib.sh
. "$repo_root/scripts/mcp-daily-lib.sh"
select_sql="$stack/sql/backfill_entries.sql"
mcp_preflight_sql="$stack/sql/mcp_daily_preflight.sql"
mcp_history_sql="$stack/sql/mcp_daily_history.sql"
target="$project.logs_daily.backfill_entries"
mcp_target="$project.logs_daily.mcp_daily"
staging="$project.logs_daily.backfill_staging"
staging_ref="$project:logs_daily.backfill_staging"

# The cut-off the entries view and the scheduled query use, from the file
# Terraform reads, trimmed as Terraform's trimspace does.
cutoff="$(cat "$stack/logs_backfill_cutoff.txt")"
cutoff="${cutoff#"${cutoff%%[![:space:]]*}"}"
cutoff="${cutoff%"${cutoff##*[![:space:]]}"}"
if ! [[ "$cutoff" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\+00$ ]]; then
    echo "load-logs-backfill.sh: expected one line YYYY-MM-DD HH:MM:SS+00 in $stack/logs_backfill_cutoff.txt, found: ${cutoff:-none}" >&2
    exit 1
fi

mcp_set_refs "$project" "$cutoff"

# The load reads only these folders. The copy writes others, and a log id
# holding a path, such as /var/log/nginx/access.log, makes object names with
# "//" that a load URI cannot name. A wildcard matching nothing fails the
# whole load, so the URIs name only the folders that hold a .json object.
listing="$(gcloud storage ls -r "$bucket")"
uris=""
stderr_objects=0
for log in requests stdout stderr; do
    folder="$bucket/run.googleapis.com/$log"
    objects="$(grep -F "$folder/" <<<"$listing" | grep -c '\.json$' || true)"
    echo ">> $folder holds $objects .json objects"
    if [ "$objects" -gt 0 ]; then
        uris="${uris:+$uris,}$folder/*"
    fi
    if [ "$log" = stderr ]; then
        stderr_objects="$objects"
    fi
done
if [ -z "$uris" ]; then
    echo "load-logs-backfill.sh: $bucket/run.googleapis.com/{requests,stdout,stderr} hold no .json object; run gcloud logging copy first." >&2
    exit 1
fi
# The combined MCP server logs its call lines to stderr, so a copy without
# that folder would write mcp_daily's days empty.
if [ -z "$skip_mcp_daily" ] && [ "$stderr_objects" -eq 0 ]; then
    echo "load-logs-backfill.sh: $bucket/run.googleapis.com/stderr holds no .json object, so mcp_daily would load empty; copy it first, or pass --skip-mcp-daily." >&2
    exit 1
fi

bq_flags=(--project_id="$project" --location=EU)

# The deployed scheduled query must call logs_daily.parse_mcp_line, which
# arrives with the apply that keeps the query's mcp_daily DELETE after the
# cut-off day, and must hold the same cut-off, since the two writers split
# mcp_daily's days there. An older query's next run deletes the days the step
# writes.
if [ -z "$skip_mcp_daily" ]; then
    if ! configs="$(bq "${bq_flags[@]}" ls --transfer_config --transfer_location=EU --format=json)"; then
        printf '%s\n' "$configs" >&2
        exit 1
    fi
    config="$(jq -r --arg name "$namespace-logs-daily" '[.[] | select(.displayName == $name) | .name] | select(length == 1) | .[0]' <<<"$configs")"
    if [ -z "$config" ]; then
        echo "load-logs-backfill.sh: expected one scheduled query named $namespace-logs-daily in $project." >&2
        exit 1
    fi
    if ! deployed="$(bq "${bq_flags[@]}" show --format=json --transfer_config "$config")"; then
        printf '%s\n' "$deployed" >&2
        exit 1
    fi
    deployed_query="$(jq -r '.params.query' <<<"$deployed")"
    if ! grep -qF -- "\`$project.logs_daily.parse_mcp_line\`(" <<<"$deployed_query"; then
        echo "load-logs-backfill.sh: the deployed $namespace-logs-daily query does not call logs_daily.parse_mcp_line; apply infra/dfo-prod/telemetry first, or pass --skip-mcp-daily." >&2
        exit 1
    fi
    if ! grep -qF -- "TIMESTAMP '$cutoff'" <<<"$deployed_query"; then
        echo "load-logs-backfill.sh: the deployed $namespace-logs-daily query does not hold the cut-off TIMESTAMP '$cutoff' of $stack/logs_backfill_cutoff.txt; apply infra/dfo-prod/telemetry first, or pass --skip-mcp-daily." >&2
        exit 1
    fi
    echo ">> The deployed $namespace-logs-daily query calls logs_daily.parse_mcp_line and holds the cut-off $cutoff"
fi

if [ -z "$skip_copy_check" ]; then
    operations="$(gcloud logging operations list --project="$project" --location=global \
        --operation-filter=request_type=CopyLogEntries --format=json)"
    # One "<id> <state>" line per copy into <bucket> that is not ignored.
    copies="$(jq -r --arg dest "storage.googleapis.com/${bucket#gs://}" --argjson ignored "$ignored" '
        .[] | select(.metadata.destination == $dest)
        | (.name | split("/") | last) as $id | select($ignored | index($id) | not)
        | "\($id) \(.metadata.state)"
    ' <<<"$operations")"
    if [ -z "$copies" ]; then
        echo "load-logs-backfill.sh: no copy into $bucket is on record; pass --skip-copy-check if the records have expired." >&2
        exit 1
    fi
    echo ">> Copies into $bucket:"
    echo "$copies"
    if grep -qv ' OPERATION_STATE_SUCCEEDED$' <<<"$copies"; then
        echo "load-logs-backfill.sh: a copy into $bucket has not succeeded, so its days may be part-written." >&2
        echo "Wait for it, or rerun the copy, or pass --ignore-operation=<id> for a cancelled copy a later one repeats." >&2
        exit 1
    fi
fi

# The checks of the mcp_daily step that need no staged copy, run before the
# bucket is loaded.
if [ -z "$skip_mcp_daily" ]; then
    echo ">> Checking $mcp_target and dfo_logs"
    preflight_script="$(fill_mcp_sql <"$mcp_preflight_sql")"
    if ! preflight_out="$(bq --quiet "${bq_flags[@]}" query --use_legacy_sql=false <<<"$preflight_script")"; then
        printf '%s\n' "$preflight_out" >&2
        echo "load-logs-backfill.sh: the $mcp_target preflight failed." >&2
        exit 1
    fi
fi

work="$(mktemp -d)"
trap 'bq rm -f -t "$staging_ref" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

# The LogEntry JSON fields backfill_entries.sql reads. --ignore_unknown_values
# drops the rest, nested fields included. logger and message are JSON, which
# takes a value of any type. timestamp stays a string, since its nanoseconds do not
# load into TIMESTAMP.
cat >"$work/schema.json" <<'JSON'
[
  {"name": "timestamp", "type": "STRING"},
  {"name": "logName", "type": "STRING"},
  {"name": "insertId", "type": "STRING"},
  {"name": "severity", "type": "STRING"},
  {"name": "resource", "type": "RECORD", "fields": [
    {"name": "type", "type": "STRING"},
    {"name": "labels", "type": "JSON"}
  ]},
  {"name": "httpRequest", "type": "RECORD", "fields": [
    {"name": "requestMethod", "type": "STRING"},
    {"name": "requestUrl", "type": "STRING"},
    {"name": "status", "type": "INTEGER"},
    {"name": "latency", "type": "STRING"}
  ]},
  {"name": "jsonPayload", "type": "RECORD", "fields": [
    {"name": "logger", "type": "JSON"},
    {"name": "message", "type": "JSON"}
  ]}
]
JSON

echo ">> Loading $uris into $staging"
bq "${bq_flags[@]}" rm -f -t "$staging_ref"
bq "${bq_flags[@]}" mk --table --expiration=86400 \
    --description="Staging for scripts/load-logs-backfill.sh. Deleted when the script exits." \
    "$staging_ref" "$work/schema.json"
bq "${bq_flags[@]}" load --source_format=NEWLINE_DELIMITED_JSON --ignore_unknown_values \
    "$staging_ref" "$uris"

select="$(cat "$select_sql")"
# shellcheck disable=SC2016 # the patterns are the template's literal placeholders
select="${select//'${staging}'/$staging}"
# shellcheck disable=SC2016
select="${select//'${namespace}'/$namespace}"
# The query's message column is not one of these, so it stays out of the
# table.
columns="timestamp, log_id, severity, resource, http_request, json_payload"

if [ -z "$skip_mcp_daily" ]; then
    mcp_script="$(fill_mcp_sql "$select" <"$mcp_history_sql")"

    echo ">> Replacing the whole days of $mcp_target through the cut-off day, $cutoff"
    # The script drops its temp tables at its end, so the days it wrote are
    # the rows mcp_report reads from the output.
    if ! mcp_out="$(bq --quiet "${bq_flags[@]}" query --use_legacy_sql=false --format=csv --max_rows=1000 <<<"$mcp_script")"; then
        printf '%s\n' "$mcp_out" >&2
        echo "load-logs-backfill.sh: the $mcp_target step failed; $mcp_target is unchanged unless the step's transaction committed before the error, in which case its days were replaced. $target was not replaced." >&2
        exit 1
    fi
    # The step's transaction has committed by now.
    mcp_days="$(mcp_report "$mcp_out")"
    if [ -z "$mcp_days" ]; then
        printf '%s\n' "$mcp_out" >&2
        echo "load-logs-backfill.sh: $mcp_target was written but its report could not be read; $target was not replaced." >&2
        exit 1
    fi
    echo ">> MCP calls written per UTC day in $mcp_target (day,calls)"
    echo "$mcp_days"
    echo ">> $(grep -c . <<<"$mcp_days") MCP days written"
fi

echo ">> Replacing $target"
bq "${bq_flags[@]}" query --use_legacy_sql=false "MERGE \`$target\` AS t
USING (
$select
) AS s
ON FALSE
WHEN NOT MATCHED THEN INSERT ($columns) VALUES ($columns)
WHEN NOT MATCHED BY SOURCE THEN DELETE"

echo ">> Entries per UTC day in $target"
report="$(bq "${bq_flags[@]}" query --use_legacy_sql=false --format=csv --max_rows=1000 \
    "SELECT DATE(timestamp) AS day, COUNT(*) AS entries FROM \`$target\` GROUP BY day ORDER BY day")"
echo "$report"
days="$(($(wc -l <<<"$report") - 1))"
if [ "$days" -le 0 ]; then
    echo "load-logs-backfill.sh: $target holds no entries after the load." >&2
    exit 1
fi
echo ">> $days days loaded"
