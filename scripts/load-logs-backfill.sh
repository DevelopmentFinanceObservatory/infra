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
# The caller needs bigquery.tables.create, updateData and delete on
# logs_daily, bigquery.jobs.create on <project>, storage.objects.list and get
# on <bucket>, and logging.operations.list on <project>.
#
# Usage: scripts/load-logs-backfill.sh [--ignore-operation=<id>]... [--skip-copy-check] <project> <namespace> <bucket>
#   scripts/load-logs-backfill.sh example-project dfo-prod gs://example-project-logs-backfill
set -euo pipefail

print_usage() {
    sed -n '/^# Usage:/,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
}

skip_copy_check=""
ignored='[]'
args=()
for arg in "$@"; do
    case "$arg" in
    -h | --help)
        print_usage
        exit 0
        ;;
    --skip-copy-check) skip_copy_check=1 ;;
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
select_sql="$repo_root/infra/stacks/telemetry/sql/backfill_entries.sql"
target="$project.logs_daily.backfill_entries"
staging="$project.logs_daily.backfill_staging"
staging_ref="$project:logs_daily.backfill_staging"

# The load reads only these folders. The copy writes others, and a log id
# holding a path, such as /var/log/nginx/access.log, makes object names with
# "//" that a load URI cannot name. A wildcard matching nothing fails the
# whole load, so the URIs name only the folders that hold a .json object.
listing="$(gcloud storage ls -r "$bucket")"
uris=""
for log in requests stdout stderr; do
    folder="$bucket/run.googleapis.com/$log"
    objects="$(grep -F "$folder/" <<<"$listing" | grep -c '\.json$' || true)"
    echo ">> $folder holds $objects .json objects"
    if [ "$objects" -gt 0 ]; then
        uris="${uris:+$uris,}$folder/*"
    fi
done
if [ -z "$uris" ]; then
    echo "load-logs-backfill.sh: $bucket/run.googleapis.com/{requests,stdout,stderr} hold no .json object; run gcloud logging copy first." >&2
    exit 1
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

bq_flags=(--project_id="$project" --location=EU)

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
columns="timestamp, log_id, severity, resource, http_request, json_payload"

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
