#!/usr/bin/env bash
# Tests sql/reporting/cloudflare_pages_daily.sql against literal rows in
# web_history.cloudflare_pages_daily's schema
# (scripts/load-cloudflare-pages-history.sh). Not wired into CI. Run by hand
# after touching the view:
#   infra/stacks/telemetry/tests/reporting_cloudflare_pages.test.sh [project]
#
# The view renames date to day and passes the path and both counts through,
# so two paths on one day stay two rows, and a path with more verified-bot
# loads than other loads keeps both as loaded.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"

SOURCES="WITH
  history AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<date DATE, path STRING, page_loads INT64, verified_bot_page_loads INT64>>[
    ('2026-10-05', '/prototypes', 40, 2),
    ('2026-10-05', '/prototypes/debt', 9, 0),
    ('2026-10-07', '/prototypes/oda-counts', 3, 11)])
  )"

check cloudflare_pages_daily \
    '{"day":"2026-10-05","path":"/prototypes","page_loads":40,"verified_bot_page_loads":2}
{"day":"2026-10-05","path":"/prototypes/debt","page_loads":9,"verified_bot_page_loads":0}
{"day":"2026-10-07","path":"/prototypes/oda-counts","page_loads":3,"verified_bot_page_loads":11}' \
    "$(view_rows cloudflare_pages_daily 't.day, t.path' history=history)"

finish reporting_cloudflare_pages.test.sh
