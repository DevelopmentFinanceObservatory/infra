#!/usr/bin/env bash
# Load Cloudflare page loads per UTC day and path from a captured file into
# web_history, for pages that GA4 does not cover, such as the prototypes app
# under /prototypes, which a Cloudflare Worker serves.
#
# Usage: scripts/load-cloudflare-pages-history.sh <rows.jsonl> <start_date> <end_date>
#   scripts/load-cloudflare-pages-history.sh prototypes.jsonl 2026-10-20 2026-11-17
#
# <rows.jsonl> holds one JSON object per line, UTC day and path, with date
# (YYYY-MM-DD), path (starting with /), page_loads and verified_bot_page_loads,
# as the per-page GraphQL query in infra/dfo-prod/telemetry/README.md
# ("Cloudflare page loads") gives them. Writes
# web_history.cloudflare_pages_daily, replacing every day from start to end,
# both inclusive, so re-running a range with the same file gives the same
# table. A day in the range that the file leaves out has no rows afterwards.
# The file must hold at least one row, every row's date must fall in the range,
# and no date and path may repeat. As in load-cloudflare-history.sh, the end
# date may be as late as yesterday (UTC), and today is refused.
# Runs as the telemetry stack's web_history_service_account
# (infra/dfo-prod/telemetry/README.md, "Web history before the exports").
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/web-history-lib.sh
. "$repo_root/scripts/web-history-lib.sh"

[ $# -eq 3 ] || { echo "usage: load-cloudflare-pages-history.sh <rows.jsonl> <start_date> <end_date>" >&2; exit 2; }
file="$1" start="$2" end="$3"
[ -f "$file" ] && [ -r "$file" ] || { echo "cannot read $file" >&2; exit 2; }
wh_check_ended "$start" "$end"
rows="$(wh_read_rows "$file" "$start" "$end" path "page_loads verified_bot_page_loads")" || exit

# shellcheck disable=SC2119 # the file is the source, so no API scope
wh_init
printf '%s\n' "$rows" >"$wh_work/pages.json"

wh_stage cloudflare_pages_daily '[
    {"name": "date", "type": "DATE", "mode": "REQUIRED", "description": "UTC day, as Cloudflare reports it."},
    {"name": "path", "type": "STRING", "mode": "REQUIRED", "description": "Request path without the query string, as Cloudflare reports it."},
    {"name": "page_loads", "type": "INT64", "mode": "REQUIRED", "description": "Cloudflare eyeball GET requests for the path answered 200 with HTML on developmentfinance.org and www, from no verified bot."},
    {"name": "verified_bot_page_loads", "type": "INT64", "mode": "REQUIRED", "description": "The same requests from verified bots."}
]' "$wh_work/pages.json"
wh_replace "$start" "$end"

echo "Loaded Cloudflare page loads per path into $wh_project.$wh_dataset.cloudflare_pages_daily, $start to $end:"
jq -r '[.date, .path, .page_loads, .verified_bot_page_loads] | @tsv' <<<"$rows" |
    { printf 'date\tpath\tpage_loads\tverified_bot_page_loads\n'; cat; }
