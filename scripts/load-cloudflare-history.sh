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
wh_check_ended "$start" "$end"
rows="$(wh_read_rows "$file" "$start" "$end" "" "page_loads verified_bot_page_loads")" || exit

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
