#!/usr/bin/env bash
# Load daily Cloudflare page loads from a captured file into web_history, for
# the days before the website's request log records status and bot fields.
#
# Usage: scripts/load-cloudflare-history.sh <rows.jsonl> <start_date> <end_date>
#   scripts/load-cloudflare-history.sh cloudflare.jsonl 2026-10-05 2026-10-23
#
# <rows.jsonl> holds one JSON object per line and UTC day, with date
# (YYYY-MM-DD), page_loads and verified_bot_page_loads, as the GraphQL query in
# infra/dfo-prod/telemetry/README.md ("Cloudflare page loads") gives them.
# Writes web_history.cloudflare_daily, replacing every day from start to end,
# both inclusive, so re-running a range with the same file gives the same
# table. A day in the range that the file leaves out has no row afterwards.
# The file must hold at least one row, every row's date must fall in the range,
# and no date may repeat. Cloudflare's figures are final once the UTC day ends,
# so the end date may be as late as yesterday (UTC), in place of the 4-day rule
# of the GA4 and Search Console loaders. Today is refused, since a run replaces
# its whole range and today's figures are still partial.
# Runs as the telemetry stack's web_history_service_account
# (infra/dfo-prod/telemetry/README.md, "Web history before the exports").
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/web-history-lib.sh
. "$repo_root/scripts/web-history-lib.sh"

[ $# -eq 3 ] || { echo "usage: load-cloudflare-history.sh <rows.jsonl> <start_date> <end_date>" >&2; exit 2; }
file="$1" start="$2" end="$3"
[ -f "$file" ] && [ -r "$file" ] || { echo "cannot read $file" >&2; exit 2; }
wh_check_range "$start" "$end"
yesterday="$(jq -rn 'now - 86400 | todate[0:10]')"
[[ ! "$end" > "$yesterday" ]] || {
    echo "end date $end has not ended in UTC, so its figures are partial; the latest end date today is $yesterday" >&2
    exit 2
}

# Each row, cut to the table's three fields, or the first problem with the
# file. A problem comes out on stdout with an "error: " prefix, so one jq run
# both checks and normalises.
rows="$(jq -rs --arg s "$start" --arg e "$end" '
    def count: type == "number" and . == floor and . >= 0;
    def real_day: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
        and (strptime("%Y-%m-%d") | mktime | todate[0:10]) == .;
    def bad: type != "object" or (.date | real_day | not)
        or (.page_loads | count | not) or (.verified_bot_page_loads | count | not);
    if length == 0 then "error: the file holds no rows"
    elif any(.[]; bad) then "error: rows without a YYYY-MM-DD date and whole, non-negative page_loads and verified_bot_page_loads:\n\(map(select(bad) | tojson) | join("\n"))"
    elif any(.[]; .date < $s or .date > $e) then "error: dates outside \($s) to \($e):\n\(map(.date | select(. < $s or . > $e)) | join("\n"))"
    elif (map(.date) | unique | length) < length then "error: dates on more than one row:\n\(map(.date) | group_by(.) | map(select(length > 1) | .[0]) | join("\n"))"
    else sort_by(.date)[] | {date, page_loads, verified_bot_page_loads} | tojson
    end' "$file")" || { echo "$file is not JSON lines" >&2; exit 2; }
[[ "$rows" != error:* ]] || { printf '%s\n' "${rows#error: }" >&2; exit 2; }

# shellcheck disable=SC2119 # the file is the source, so no API scope
wh_init
printf '%s\n' "$rows" >"$wh_work/daily.json"

wh_stage cloudflare_daily '[
    {"name": "date", "type": "DATE", "mode": "REQUIRED", "description": "UTC day, as Cloudflare reports it."},
    {"name": "page_loads", "type": "INT64", "mode": "REQUIRED", "description": "Cloudflare eyeball GET requests answered 200 with HTML on developmentfinance.org and www, from no verified bot."},
    {"name": "verified_bot_page_loads", "type": "INT64", "mode": "REQUIRED", "description": "The same requests from verified bots."}
]' "$wh_work/daily.json"
wh_replace "$start" "$end"

echo "Loaded Cloudflare page loads into $wh_project.$wh_dataset.cloudflare_daily, $start to $end:"
jq -r '[.date, .page_loads, .verified_bot_page_loads] | @tsv' <<<"$rows" |
    { printf 'date\tpage_loads\tverified_bot_page_loads\n'; cat; }
