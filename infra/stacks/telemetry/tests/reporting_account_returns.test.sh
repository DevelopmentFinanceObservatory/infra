#!/usr/bin/env bash
# Tests sql/reporting/account_returns_daily.sql against literal rows in the
# website export's event schema (dfo-website db/event-export.ts). Not wired
# into CI. Run by hand after touching the view:
#   infra/stacks/telemetry/tests/reporting_account_returns.test.sh [project]
#
# Account u1 is active on 2026-10-05, twice that day, and again on 2026-10-07.
# Account u3 is active on all three days 2026-10-05 to 2026-10-07, and account
# u2 on 2026-10-05 only. Account u4 first appears on 2026-10-06 and returns on
# 2026-10-07, so it is new on 2026-10-06 although the table's first day is
# earlier. Visitor v9 sends signed-out events on 2026-10-08 and on 2026-10-06,
# so 2026-10-08 has no signed-in event and no row. The sketches count distinct
# accounts: u1 counts once on 2026-10-05, and merged over 2026-10-06 and
# 2026-10-07 the returning sketches hold u3, u1 and u4 where the two days hold
# four returns between them.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"

SOURCES="WITH
  events AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<id INT64, created_at TIMESTAMP, name STRING, page STRING,
      signed_in BOOL, visitor_hash STRING, user_hash STRING, props JSON>>[
    (1, '2026-10-05 09:00:00+00', 'studio.prompt', '/studio', TRUE, 'v1', 'u1', JSON '{}'),
    (2, '2026-10-05 09:30:00+00', 'studio.prompt', '/studio', TRUE, 'v1', 'u1', JSON '{}'),
    (3, '2026-10-05 10:00:00+00', 'studio.prompt', '/studio', TRUE, 'v2', 'u2', JSON '{}'),
    (4, '2026-10-05 23:59:59+00', 'studio.prompt', '/studio', TRUE, 'v3', 'u3', JSON '{}'),
    (5, '2026-10-06 00:00:00+00', 'studio.prompt', '/studio', TRUE, 'v3', 'u3', JSON '{}'),
    (6, '2026-10-06 08:00:00+00', 'search.query', '/search', FALSE, 'v9', NULL, JSON '{}'),
    (7, '2026-10-07 07:00:00+00', 'studio.prompt', '/studio', TRUE, 'v1', 'u1', JSON '{}'),
    (8, '2026-10-07 08:00:00+00', 'studio.prompt', '/studio', TRUE, 'v3', 'u3', JSON '{}'),
    (9, '2026-10-08 08:00:00+00', 'search.query', '/search', FALSE, 'v9', NULL, JSON '{}'),
    (10, '2026-10-06 11:00:00+00', 'studio.prompt', '/studio', TRUE, 'v4', 'u4', JSON '{}'),
    (11, '2026-10-07 11:00:00+00', 'studio.prompt', '/studio', TRUE, 'v4', 'u4', JSON '{}')])
  )"

VIEW="$(view_sql account_returns_daily events=events)"

check account_returns_daily \
    '{"day":"2026-10-05","active":3,"returning":0,"returning_sketch_null":true}
{"day":"2026-10-06","active":2,"returning":1,"returning_sketch_null":false}
{"day":"2026-10-07","active":3,"returning":3,"returning_sketch_null":false}' \
    "$(query_rows "SELECT TO_JSON_STRING(t) AS row FROM (
  SELECT day, HLL_COUNT.EXTRACT(active_sketch) AS active,
    HLL_COUNT.EXTRACT(returning_sketch) AS returning,
    returning_sketch IS NULL AS returning_sketch_null
  FROM ($VIEW)
) AS t
ORDER BY t.day")"

check 'account_returns_daily merged over the window and over the last two days' \
    '{"span":"all","active":4,"returning":3}
{"span":"last two days","active":3,"returning":3}' \
    "$(query_rows "SELECT TO_JSON_STRING(t) AS row FROM (
  SELECT 'all' AS span, HLL_COUNT.MERGE(active_sketch) AS active,
    HLL_COUNT.MERGE(returning_sketch) AS returning
  FROM ($VIEW)
  UNION ALL
  SELECT 'last two days', HLL_COUNT.MERGE(active_sketch), HLL_COUNT.MERGE(returning_sketch)
  FROM ($VIEW)
  WHERE day >= DATE '2026-10-06'
) AS t
ORDER BY t.span")"

finish reporting_account_returns.test.sh
