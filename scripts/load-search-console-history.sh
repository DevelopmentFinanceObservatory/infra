#!/usr/bin/env bash
# Load daily Search Console history from the Search Analytics API into
# web_history, for the days before the bulk data export starts.
#
# Usage: scripts/load-search-console-history.sh <site_url> <start_date> <end_date>
#   scripts/load-search-console-history.sh sc-domain:developmentfinance.org 2026-10-05 2026-10-20
#
# <site_url> is the property as Search Console names it: sc-domain:<domain>
# for a Domain property, or the URL prefix with its trailing slash.
#
# Writes web_history.search_console_pages_daily (per day and page) and
# web_history.search_console_daily (per day, for the whole property), replacing
# every day from start to end, both inclusive. Re-running a range gives the
# same tables. It reads final web-search data and requests no query dimension.
# Days are Pacific Time, as Search Console reports them.
# Runs as the telemetry stack's web_history_service_account
# (infra/dfo-prod/telemetry/README.md, "Web history before the exports").
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/web-history-lib.sh
. "$repo_root/scripts/web-history-lib.sh"

[ $# -eq 3 ] || { echo "usage: load-search-console-history.sh <site_url> <start_date> <end_date>" >&2; exit 2; }
site="$1" start="$2" end="$3"
[[ "$site" =~ ^(sc-domain:.+|https?://.+/)$ ]] || {
    echo "site URL must be sc-domain:<domain> or a URL prefix ending in /: $site" >&2
    exit 2
}
wh_check_dates "$start" "$end"
wh_init https://www.googleapis.com/auth/webmasters.readonly

url="https://searchconsole.googleapis.com/webmasters/v3/sites/$(jq -rn --arg s "$site" '$s | @uri')/searchAnalytics/query"

# request <dimension>...: a query body over the range.
request() {
    jq -n --arg s "$start" --arg e "$end" '{
        startDate: $s,
        endDate: $e,
        dimensions: $ARGS.positional,
        type: "web",
        dataState: "final"
    }' --args "$@"
}

# The API reports an average position per row, with the top position as 1.
# sum_position is on the bulk export's scale, with the top position as 0, and
# weighted by impressions, so history and export rows sum alike and
# sum_position / impressions + 1 is the average position.
metrics='def metrics: {clicks, impressions, sum_position: ((.position - 1) * .impressions)};'

# sum_by_url: drops the query string and fragment from each URL and sums the
# rows that then share a date and URL. All three metrics are additive.
sum_by_url() {
    jq -sc 'map(.url |= sub("[?#].*$"; ""))
        | group_by([.date, .url])
        | map({date: .[0].date, url: .[0].url, clicks: (map(.clicks) | add),
            impressions: (map(.impressions) | add), sum_position: (map(.sum_position) | add)})
        | .[]'
}

wh_pages "$url" "$(request date page)" startRow rowLimit |
    jq -c "$metrics"' {date: .keys[0], url: .keys[1]} + metrics' |
    sum_by_url >"$wh_work/pages.json"
wh_pages "$url" "$(request date)" startRow rowLimit |
    jq -c "$metrics"' {date: .keys[0]} + metrics' >"$wh_work/daily.json"

metric_fields='[
    {"name": "clicks", "type": "INT64", "mode": "REQUIRED", "description": "Clicks from web search."},
    {"name": "impressions", "type": "INT64", "mode": "REQUIRED", "description": "Impressions in web search."},
    {"name": "sum_position", "type": "FLOAT64", "mode": "REQUIRED", "description": "Sum over impressions of the position, with the top position as 0, as in the bulk export; sum_position / impressions + 1 is the average position."}
]'
date_field='{"name": "date", "type": "DATE", "mode": "REQUIRED", "description": "Day in Pacific Time, as Search Console reports it."}'
url_field='{"name": "url", "type": "STRING", "mode": "REQUIRED", "description": "Page URL with any query string and fragment removed."}'

wh_stage search_console_pages_daily "$(jq -n --argjson d "$date_field" --argjson u "$url_field" --argjson m "$metric_fields" '[$d, $u] + $m')" "$wh_work/pages.json"
wh_stage search_console_daily "$(jq -n --argjson d "$date_field" --argjson m "$metric_fields" '[$d] + $m')" "$wh_work/daily.json"
wh_replace "$start" "$end"

echo "Loaded Search Console property $site into $wh_project.$wh_dataset, $start to $end. Rows per day:"
wh_print_days "$start" "$end" search_console_pages_daily "$wh_work/pages.json" search_console_daily "$wh_work/daily.json"
