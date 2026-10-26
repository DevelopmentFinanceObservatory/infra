#!/usr/bin/env bash
# Tests sql/reporting/website_page_views_daily.sql against literal rows in
# logs_daily.website_requests_daily's schema (sql/logs_daily.sql) and
# web_history.website_page_history's (scripts/load-website-page-history.sh).
# Not wired into CI. Run by hand after touching the view:
#   infra/stacks/telemetry/tests/reporting_website_page_views.test.sh [project]
#
# The request log holds only unparsed rows on 2026-10-23, so its first
# parsed day is 2026-10-24. The history rows for 2026-10-22 and 2026-10-23
# are kept and the one for 2026-10-24 is left out. On 2026-10-24 only page
# rows answered 2xx count, split by bot over two routes. 2026-10-26 holds
# only unparsed rows and has no row, and 2026-10-27 holds parsed rows but no
# page view and has a row of zeros. With only the unparsed rows in the log,
# every history row is kept.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"

SOURCES="WITH
  website_requests_daily AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<day DATE, route STRING, kind STRING, bot BOOL,
      status_class INT64, requests INT64, callers_sketch BYTES>>[
    ('2026-10-23', NULL, 'unparsed', NULL, NULL, 1043, NULL),
    ('2026-10-24', '/', 'page', FALSE, 2, 300, NULL),
    ('2026-10-24', '/data/:id', 'page', FALSE, 2, 139, NULL),
    ('2026-10-24', '/', 'page', TRUE, 2, 50, NULL),
    ('2026-10-24', '/', 'page', FALSE, 3, 7, NULL),
    ('2026-10-24', '/missing', 'page', FALSE, 4, 5, NULL),
    ('2026-10-24', '/', 'rsc', FALSE, 2, 80, NULL),
    ('2026-10-24', '/api/search', 'api', FALSE, 2, 20, NULL),
    ('2026-10-24', '/', 'prefetch', FALSE, 2, 10, NULL),
    ('2026-10-24', NULL, 'unparsed', NULL, NULL, 3, NULL),
    ('2026-10-25', '/', 'page', FALSE, 2, 674, NULL),
    ('2026-10-25', '/', 'page', TRUE, 2, 20, NULL),
    ('2026-10-26', NULL, 'unparsed', NULL, NULL, 4, NULL),
    ('2026-10-27', '/api/search', 'api', FALSE, 2, 5, NULL)])
  ),
  unparsed_only AS (
    SELECT * FROM website_requests_daily WHERE kind = 'unparsed'
  ),
  history AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<date DATE, page_views INT64, bot_page_views INT64>>[
    ('2026-10-22', 500, 40),
    ('2026-10-23', 731, 60),
    ('2026-10-24', 999, 99)])
  )"

check website_page_views_daily \
    '{"day":"2026-10-22","page_views":500,"bot_page_views":40}
{"day":"2026-10-23","page_views":731,"bot_page_views":60}
{"day":"2026-10-24","page_views":439,"bot_page_views":50}
{"day":"2026-10-25","page_views":674,"bot_page_views":20}
{"day":"2026-10-27","page_views":0,"bot_page_views":0}' \
    "$(view_rows website_page_views_daily 't.day' website_requests_daily=website_requests_daily history=history)"

check 'website_page_views_daily, no parsed day' \
    '{"day":"2026-10-22","page_views":500,"bot_page_views":40}
{"day":"2026-10-23","page_views":731,"bot_page_views":60}
{"day":"2026-10-24","page_views":999,"bot_page_views":99}' \
    "$(view_rows website_page_views_daily 't.day' website_requests_daily=unparsed_only history=history)"

finish reporting_website_page_views.test.sh
