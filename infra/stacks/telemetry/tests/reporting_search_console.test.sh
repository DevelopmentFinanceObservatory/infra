#!/usr/bin/env bash
# Tests sql/reporting/search_console_daily.sql and search_console_pages.sql
# against literal rows in web_history's schemas
# (scripts/load-search-console-history.sh) and the bulk export's
# searchdata_site_impression and searchdata_url_impression schemas, cut to
# the fields the views read. Not wired into CI. Run by hand after touching
# either view:
#   infra/stacks/telemetry/tests/reporting_search_console.test.sh [project]
#
# Each export's first day is 2026-10-06, so the history rows for that day
# are left out and the earlier ones kept. Image-search rows are left out.
# The export's query rows sum, the anonymised one included. On 2026-10-06 the
# URLs /a?utm=x, /a#s and /a are one page, as the history loader stores it,
# and /b?q=1#f is /b.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"

SITE='https://developmentfinance.org'
SOURCES="WITH
  history_daily AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<date DATE, clicks INT64, impressions INT64,
      sum_position FLOAT64>>[
    ('2026-10-05', 10, 100, 50.0),
    ('2026-10-06', 99, 999, 99.0)])
  ),
  history_pages AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<date DATE, url STRING, clicks INT64, impressions INT64,
      sum_position FLOAT64>>[
    ('2026-10-05', '$SITE/a', 4, 40, 8.0),
    ('2026-10-06', '$SITE/a', 99, 999, 99.0)])
  ),
  site_impressions AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<data_date DATE, search_type STRING, query STRING,
      is_anonymized_query BOOL, clicks INT64, impressions INT64, sum_top_position FLOAT64>>[
    ('2026-10-06', 'WEB', 'development finance', FALSE, 2, 20, 10.0),
    ('2026-10-06', 'WEB', NULL, TRUE, 1, 5, 4.0),
    ('2026-10-06', 'IMAGE', 'development finance', FALSE, 7, 70, 7.0),
    ('2026-10-07', 'WEB', 'oda', FALSE, 3, 30, 0.0)])
  ),
  url_impressions AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<data_date DATE, search_type STRING, url STRING,
      clicks INT64, impressions INT64, sum_position FLOAT64>>[
    ('2026-10-06', 'WEB', '$SITE/a?utm=x', 1, 10, 2.0),
    ('2026-10-06', 'WEB', '$SITE/a#s', 1, 5, 1.0),
    ('2026-10-06', 'WEB', '$SITE/a', 2, 10, 0.0),
    ('2026-10-06', 'WEB', '$SITE/b?q=1#f', 0, 3, 6.0),
    ('2026-10-06', 'IMAGE', '$SITE/a', 5, 5, 5.0)])
  )"

check search_console_daily \
    '{"day":"2026-10-05","clicks":10,"impressions":100,"sum_position":50}
{"day":"2026-10-06","clicks":3,"impressions":25,"sum_position":14}
{"day":"2026-10-07","clicks":3,"impressions":30,"sum_position":0}' \
    "$(view_rows search_console_daily 't.day' site_impressions=site_impressions history=history_daily)"

check search_console_pages \
    "{\"day\":\"2026-10-05\",\"url\":\"$SITE/a\",\"clicks\":4,\"impressions\":40,\"sum_position\":8}
{\"day\":\"2026-10-06\",\"url\":\"$SITE/a\",\"clicks\":4,\"impressions\":25,\"sum_position\":3}
{\"day\":\"2026-10-06\",\"url\":\"$SITE/b\",\"clicks\":0,\"impressions\":3,\"sum_position\":6}" \
    "$(view_rows search_console_pages 't.day, t.url' url_impressions=url_impressions history=history_pages)"

finish reporting_search_console.test.sh
