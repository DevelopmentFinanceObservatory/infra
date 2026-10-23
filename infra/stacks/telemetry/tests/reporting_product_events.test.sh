#!/usr/bin/env bash
# Tests sql/reporting/product_events_daily.sql against literal rows in the
# website export's event schema (dfo-website db/event-export.ts), with
# sql/normalise_route.sql as a temporary function. Not wired into CI. Run by
# hand after touching the view:
#   infra/stacks/telemetry/tests/reporting_product_events.test.sh [project]
#
# On 2026-10-05 visitor v1 searches twice and prompts the studio once as
# user u1, visitor v2 prompts the studio as user u2 and sends feedback from
# no page. On 2026-10-06 v1 searches again. Both studio pages are
# /studio/:id, so the conversation ids do not reach the view. The sketches
# count distinct ids: merged over a day's rows they give 2 visitors where
# the rows hold 4 between them, and merged over both days 2 where the days
# hold 3.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"

SOURCES="CREATE TEMP FUNCTION normalise_route(url STRING) RETURNS STRING AS (
$(cat "$DIR/../sql/normalise_route.sql")
);
WITH
  events AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<id INT64, created_at TIMESTAMP, name STRING, page STRING,
      signed_in BOOL, visitor_hash STRING, user_hash STRING, props JSON>>[
    (1, '2026-10-05 09:00:00+00', 'search.query', '/search', FALSE, 'v1', NULL, JSON '{}'),
    (2, '2026-10-05 09:01:00+00', 'search.query', '/search', FALSE, 'v1', NULL, JSON '{}'),
    (3, '2026-10-05 10:00:00+00', 'studio.prompt', '/studio/0b0e7c1a-5f4e-4c1b-9d2a-1e3f5a7b9c0d', TRUE, 'v1', 'u1', JSON '{}'),
    (4, '2026-10-05 11:00:00+00', 'studio.prompt', '/studio/7d6c5b4a-3e2f-4a1b-8c9d-0e1f2a3b4c5d', TRUE, 'v2', 'u2', JSON '{}'),
    (5, '2026-10-05 23:59:59+00', 'feedback.submit', NULL, FALSE, 'v2', NULL, JSON '{}'),
    (6, '2026-10-06 00:00:00+00', 'search.query', '/search', FALSE, 'v1', NULL, JSON '{}')])
  )"

VIEW="$(view_sql product_events_daily events=events normalise_route=normalise_route)"

check product_events_daily \
    '{"day":"2026-10-05","event":"feedback.submit","page":null,"signed_in":false,"events":1,"visitors":1,"users":0}
{"day":"2026-10-05","event":"search.query","page":"/search","signed_in":false,"events":2,"visitors":1,"users":0}
{"day":"2026-10-05","event":"studio.prompt","page":"/studio/:id","signed_in":true,"events":2,"visitors":2,"users":2}
{"day":"2026-10-06","event":"search.query","page":"/search","signed_in":false,"events":1,"visitors":1,"users":0}' \
    "$(query_rows "SELECT TO_JSON_STRING(t) AS row FROM (
  SELECT day, event, page, signed_in, events,
    HLL_COUNT.EXTRACT(visitors_sketch) AS visitors, HLL_COUNT.EXTRACT(users_sketch) AS users
  FROM ($VIEW)
) AS t
ORDER BY t.day, t.event")"

check 'product_events_daily merged per day and over both days' \
    '{"day":"2026-10-05","events":5,"visitors":2,"users":2}
{"day":"2026-10-06","events":1,"visitors":1,"users":0}
{"day":null,"events":6,"visitors":2,"users":2}' \
    "$(query_rows "SELECT TO_JSON_STRING(t) AS row FROM (
  SELECT day, SUM(events) AS events,
    HLL_COUNT.MERGE(visitors_sketch) AS visitors, HLL_COUNT.MERGE(users_sketch) AS users
  FROM ($VIEW)
  GROUP BY GROUPING SETS ((day), ())
) AS t
ORDER BY t.day IS NULL, t.day")"

finish reporting_product_events.test.sh
