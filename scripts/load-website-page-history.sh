#!/usr/bin/env bash
# Load daily website page views, rebuilt from Cloud Run request logs, into
# web_history, for the days before the website's own request log starts.
#
# Usage: scripts/load-website-page-history.sh <rows.jsonl> <start_date> <end_date>
#   scripts/load-website-page-history.sh page-views.jsonl 2026-10-14 2026-10-23
#
# <rows.jsonl> holds one JSON object per line and UTC day, with date
# (YYYY-MM-DD), page_views and bot_page_views, as
# scripts/capture-website-page-history.sh prints them.
# Writes web_history.website_page_history, replacing every day from start to
# end, both inclusive, so re-running a range with the same file gives the same
# table. A day in the range that the file leaves out has no row afterwards.
# The file must hold at least one row, every row's date must fall in the range,
# and no date may repeat. The start may not be before 2026-10-14, since the
# public domain first reached the service at 06:21 UTC that day and earlier
# requests are preview-host traffic. A day's figures are final once the UTC day
# ends, so the end date may be as late as yesterday (UTC). Today is refused,
# since a run replaces its whole range and today's figures are still partial.
# Which of these days the dashboard reads, against the request log, is the
# decision of the analytics repository's website_page_views_daily model, so
# this loader does not check the range against the log.
# Runs as the telemetry stack's web_history_service_account
# (infra/dfo-prod/telemetry/README.md, "Web history before the exports").
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/web-history-lib.sh
. "$repo_root/scripts/web-history-lib.sh"

first_day=2026-10-14
[ $# -eq 3 ] || { echo "usage: load-website-page-history.sh <rows.jsonl> <start_date> <end_date>" >&2; exit 2; }
file="$1" start="$2" end="$3"
[ -f "$file" ] && [ -r "$file" ] || { echo "cannot read $file" >&2; exit 2; }
wh_check_ended "$start" "$end"
[[ ! "$start" < "$first_day" ]] || {
    echo "start date $start is before $first_day, when the public domain first reached the service; earlier requests came from the preview host" >&2
    exit 2
}
rows="$(wh_read_rows "$file" "$start" "$end" "" "page_views bot_page_views")" || exit

# shellcheck disable=SC2119 # the file is the source, so no API scope
wh_init
printf '%s\n' "$rows" >"$wh_work/daily.json"

wh_stage website_page_history '[
    {"name": "date", "type": "DATE", "mode": "REQUIRED", "description": "UTC day of the request, as Cloud Run logged it."},
    {"name": "page_views", "type": "INT64", "mode": "REQUIRED", "description": "Page requests answered 2xx on developmentfinance.org and www, from no bot, rebuilt from the Cloud Run request log."},
    {"name": "bot_page_views", "type": "INT64", "mode": "REQUIRED", "description": "The same requests from bots, or with no user agent."}
]' "$wh_work/daily.json"
wh_replace "$start" "$end"

echo "Loaded website page views into $wh_project.$wh_dataset.website_page_history, $start to $end:"
jq -r '[.date, .page_views, .bot_page_views] | @tsv' <<<"$rows" |
    { printf 'date\tpage_views\tbot_page_views\n'; cat; }
