#!/usr/bin/env bash
# Load daily GA4 history from the Data API into web_history, for the days
# before the GA4 BigQuery export starts.
#
# Usage: scripts/load-ga4-history.sh <ga4_property_id> <start_date> <end_date>
#   scripts/load-ga4-history.sh 123456789 2026-10-05 2026-10-20
#
# Writes web_history.ga4_pages_daily (per day and page path) and
# web_history.ga4_daily (per day; users do not sum across pages), replacing
# every day from start to end, both inclusive. Re-running a range gives the
# same tables. Days are in the property's reporting time zone, as in the export.
# Runs as the telemetry stack's web_history_service_account
# (infra/dfo-prod/telemetry/README.md, "Web history before the exports").
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/web-history-lib.sh
. "$repo_root/scripts/web-history-lib.sh"

[ $# -eq 3 ] || { echo "usage: load-ga4-history.sh <ga4_property_id> <start_date> <end_date>" >&2; exit 2; }
property="$1" start="$2" end="$3"
[[ "$property" =~ ^[0-9]+$ ]] || { echo "GA4 property id must be digits: $property" >&2; exit 2; }
wh_check_dates "$start" "$end"
wh_init https://www.googleapis.com/auth/analytics.readonly

url="https://analyticsdata.googleapis.com/v1beta/properties/${property}:runReport"

# request <dimension>...: a runReport body over the range with the three
# metrics, in the order the row filters below read them.
request() {
    jq -n --arg s "$start" --arg e "$end" '{
        dateRanges: [{startDate: $s, endDate: $e}],
        dimensions: ($ARGS.positional | map({name: .})),
        metrics: [{name: "activeUsers"}, {name: "sessions"}, {name: "screenPageViews"}]
    }' --args "$@"
}

# GA4 sends dates as YYYYMMDD and metric values as strings.
metrics='
    def day: "\(.[0:4])-\(.[4:6])-\(.[6:8])";
    def metrics: {
        active_users: (.metricValues[0].value | tonumber),
        sessions: (.metricValues[1].value | tonumber),
        screen_page_views: (.metricValues[2].value | tonumber)
    };'

wh_pages "$url" "$(request date pagePath)" offset limit |
    jq -c "$metrics"' {date: (.dimensionValues[0].value | day), page_path: .dimensionValues[1].value} + metrics' \
        >"$wh_work/pages.json"
# pagePath carries no query string, so each day has one row per path. Users
# and sessions do not sum across rows, so a repeated path stops the run.
duplicates="$(jq -rs 'group_by([.date, .page_path]) | map(select(length > 1) | .[0] | "\(.date) \(.page_path)") | .[]' "$wh_work/pages.json")"
[ -z "$duplicates" ] || {
    echo "GA4 returned more than one row for these days and page paths:" >&2
    printf '%s\n' "$duplicates" >&2
    exit 1
}
wh_pages "$url" "$(request date)" offset limit |
    jq -c "$metrics"' {date: (.dimensionValues[0].value | day)} + metrics' >"$wh_work/daily.json"

metric_fields='[
    {"name": "active_users", "type": "INT64", "mode": "REQUIRED", "description": "GA4 activeUsers."},
    {"name": "sessions", "type": "INT64", "mode": "REQUIRED", "description": "GA4 sessions."},
    {"name": "screen_page_views", "type": "INT64", "mode": "REQUIRED", "description": "GA4 screenPageViews."}
]'
date_field='{"name": "date", "type": "DATE", "mode": "REQUIRED", "description": "Day in the GA4 property'"'"'s reporting time zone."}'
page_field='{"name": "page_path", "type": "STRING", "mode": "REQUIRED", "description": "GA4 pagePath, the URL path without its query string, as the Data API returns it."}'

wh_stage ga4_pages_daily "$(jq -n --argjson d "$date_field" --argjson p "$page_field" --argjson m "$metric_fields" '[$d, $p] + $m')" "$wh_work/pages.json"
wh_stage ga4_daily "$(jq -n --argjson d "$date_field" --argjson m "$metric_fields" '[$d] + $m')" "$wh_work/daily.json"
wh_replace "$start" "$end"

echo "Loaded GA4 property $property into $wh_project.$wh_dataset, $start to $end. Rows per day:"
wh_print_days "$start" "$end" ga4_pages_daily "$wh_work/pages.json" ga4_daily "$wh_work/daily.json"
