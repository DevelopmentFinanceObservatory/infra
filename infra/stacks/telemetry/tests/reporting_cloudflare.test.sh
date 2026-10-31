#!/usr/bin/env bash
# Tests sql/reporting/cloudflare_daily.sql against literal rows in
# web_history.cloudflare_daily's schema (scripts/load-cloudflare-history.sh).
# Not wired into CI. Run by hand after touching the view:
#   infra/stacks/telemetry/tests/reporting_cloudflare.test.sh [project]
#
# The view renames date to day and passes both counts through, so a day with
# more verified-bot loads than other loads keeps both as loaded.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"

SOURCES="WITH
  history AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<date DATE, page_loads INT64, verified_bot_page_loads INT64>>[
    ('2026-10-05', 483, 6),
    ('2026-10-14', 1772, 3239)])
  )"

check cloudflare_daily \
    '{"day":"2026-10-05","page_loads":483,"verified_bot_page_loads":6}
{"day":"2026-10-14","page_loads":1772,"verified_bot_page_loads":3239}' \
    "$(view_rows cloudflare_daily 't.day' history=history)"

finish reporting_cloudflare.test.sh
