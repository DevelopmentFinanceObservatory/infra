#!/usr/bin/env bash
# Count the website's daily page views from Cloud Run's request log, for the
# days before the website's own request log, and print them as JSON lines for
# load-website-page-history.sh. Reads only; it writes nothing to Google Cloud.
#
# Usage: scripts/capture-website-page-history.sh <start_date> <end_date>
#   scripts/capture-website-page-history.sh 2026-10-14 2026-10-23 >website-page-history.jsonl
#
# For each UTC day from start to end, both inclusive, it reads
# dfo-prod-website's run.googleapis.com/requests entries with
# `gcloud logging read` and counts them with website-page-history-classify.mjs,
# which applies the website's page rule and its isbot 5.2.2 bot rule, and
# keeps only the apex and www hosts. It prints one line per day, with date
# (YYYY-MM-DD), page_views and bot_page_views, and the entries read per day on
# stderr. The lines come out together once every day is counted, so a failed
# run prints none. No URL or user agent is written to disk.
#
# The log filter keeps 2xx entries whose path does not start with /_next/,
# both of which the classifier drops anyway, so the read stays small.
# Cloud Logging's _Default bucket keeps entries for 30 days, so a day can be
# captured until 00:00 UTC thirty days after it. A start date older than
# today minus 29 days is refused, since that day has lost its first entries,
# and so is today, since its figures are partial. A day that reads no entries
# fails the run, since a public day always has some.
#
# Needs gcloud signed in with logging read access to prod-fin-observatory, jq,
# node and npm, which installs isbot 5.2.2 into a temporary directory.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/web-history-lib.sh
. "$repo_root/scripts/web-history-lib.sh"

project=prod-fin-observatory
# The public domain first reached the service at 2026-10-14 06:21 UTC. The
# entries before that are the run.app preview host, which the host rule drops.
first_day=2026-10-14

[ $# -eq 2 ] || { echo "usage: capture-website-page-history.sh <start_date> <end_date>" >&2; exit 2; }
start="$1" end="$2"
for tool in jq gcloud node npm; do
    command -v "$tool" >/dev/null || { echo "$tool not found." >&2; exit 1; }
done
wh_check_range "$start" "$end"
[[ ! "$start" < "$first_day" ]] || {
    echo "start date $start is before $first_day, when the public domain first reached the website service" >&2
    exit 2
}
# WEB_HISTORY_TODAY sets today's date, for the tests.
today="${WEB_HISTORY_TODAY:-$(jq -rn 'now | todate[0:10]')}"
yesterday="$(jq -rn --arg d "$today" '$d | strptime("%Y-%m-%d") | mktime - 86400 | todate[0:10]')"
[[ ! "$end" > "$yesterday" ]] || {
    echo "end date $end has not ended in UTC, so its figures are partial; the latest end date today is $yesterday" >&2
    exit 2
}
# The _Default bucket keeps entries for 30 days, so the oldest day it still
# holds whole is today minus 29 days. An older day has lost its first entries.
oldest="$(jq -rn --arg d "$today" '$d | strptime("%Y-%m-%d") | mktime - 29 * 86400 | todate[0:10]')"
[[ ! "$start" < "$oldest" ]] || {
    echo "start date $start is older than $oldest, the oldest day whole in Cloud Logging's _Default bucket, which keeps entries for 30 days; the figures for $start would be partial" >&2
    exit 2
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
npm install --prefix "$work" --no-save --no-package-lock --no-audit --no-fund --ignore-scripts \
    --loglevel=error isbot@5.2.2 >/dev/null

rows=()
day="$start"
while [[ ! "$day" > "$end" ]]; do
    next="$(jq -rn --arg d "$day" '$d | strptime("%Y-%m-%d") | mktime + 86400 | todate[0:10]')"
    filter="resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"dfo-prod-website\"
        AND log_id(\"run.googleapis.com/requests\")
        AND httpRequest.status>=200 AND httpRequest.status<300
        AND NOT httpRequest.requestUrl=~\"^https?://[^/]+/_next/\"
        AND timestamp>=\"${day}T00:00:00Z\" AND timestamp<\"${next}T00:00:00Z\""
    if ! row="$(gcloud logging read "$filter" --project="$project" --order=asc \
        --format='value(httpRequest.status,httpRequest.requestUrl,httpRequest.userAgent)' 2>"$work/gcloud.err" |
        node "$repo_root/scripts/website-page-history-classify.mjs" "$work" "$day")"; then
        echo "reading $day failed:" >&2
        cat "$work/gcloud.err" >&2
        exit 1
    fi
    # gcloud can warn on stderr and still exit 0, as when it stops early.
    if [ -s "$work/gcloud.err" ]; then
        echo "gcloud wrote to stderr reading $day, so the day may be incomplete:" >&2
        cat "$work/gcloud.err" >&2
        exit 1
    fi
    rows+=("$row")
    day="$next"
done

[ "${#rows[@]}" -gt 0 ] || { echo "no days were read" >&2; exit 1; }
printf '%s\n' "${rows[@]}"
