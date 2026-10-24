#!/usr/bin/env bash
# Tests sql/reporting/ga4_daily.sql and ga4_pages_daily.sql against literal
# rows in web_history's schemas (scripts/load-ga4-history.sh) and the GA4
# export's events_YYYYMMDD schema, cut to the fields the views read. Not
# wired into CI. Run by hand after touching either view:
#   infra/stacks/telemetry/tests/reporting_ga4.test.sh [project]
#
# The export's first day is 2026-10-07, so the history rows for that day
# are left out and the earlier ones kept. Export events on 2026-10-07:
#   u1, active, session 1 on /a?x=1 and /b#top, and session 2 on /a.
#   u2, active, session 1 on /a, and an event with no page_location.
#   u3, not active, session 7 on the bare host.
#   Two visitors who declined analytics storage, with no user_pseudo_id, on
#   /a and /b, and a declined user_engagement event.
# The day has 2 active users and 4 sessions, while its page rows hold 6
# sessions between them, so the day's figures are counted over its events
# and not summed from its pages. The declined events add page views and
# declined page views but no user or session. History days have no declined
# page views to report, so theirs are NULL.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"

SOURCES="WITH
  history_daily AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<date DATE, active_users INT64, sessions INT64,
      screen_page_views INT64>>[
    ('2026-10-05', 5, 6, 7),
    ('2026-10-06', 4, 4, 4),
    ('2026-10-07', 99, 99, 99)])
  ),
  history_pages AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<date DATE, page_path STRING, active_users INT64,
      sessions INT64, screen_page_views INT64>>[
    ('2026-10-06', '/', 3, 3, 3),
    ('2026-10-07', '/a', 99, 99, 99)])
  ),
  events AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<event_date STRING, event_name STRING, user_pseudo_id STRING,
      is_active_user BOOL, privacy_info STRUCT<analytics_storage STRING>,
      event_params ARRAY<STRUCT<key STRING, value STRUCT<string_value STRING, int_value INT64>>>>>[
    ('20261007', 'page_view', 'u1', TRUE, STRUCT('Yes'), [('ga_session_id', (CAST(NULL AS STRING), 1)), ('page_location', ('https://developmentfinance.org/a?x=1', NULL))]),
    ('20261007', 'page_view', 'u1', TRUE, STRUCT('Yes'), [('ga_session_id', (CAST(NULL AS STRING), 1)), ('page_location', ('https://developmentfinance.org/b#top', NULL))]),
    ('20261007', 'page_view', 'u1', TRUE, STRUCT('Yes'), [('ga_session_id', (CAST(NULL AS STRING), 2)), ('page_location', ('https://developmentfinance.org/a', NULL))]),
    ('20261007', 'page_view', 'u2', TRUE, STRUCT('Yes'), [('ga_session_id', (CAST(NULL AS STRING), 1)), ('page_location', ('https://developmentfinance.org/a', NULL))]),
    ('20261007', 'consent_update', 'u2', TRUE, STRUCT('Yes'), [('ga_session_id', (CAST(NULL AS STRING), 1))]),
    ('20261007', 'user_engagement', 'u3', FALSE, STRUCT('Yes'), [('ga_session_id', (CAST(NULL AS STRING), 7)), ('page_location', ('https://developmentfinance.org', NULL))]),
    ('20261007', 'page_view', NULL, TRUE, STRUCT('No'), [('ga_session_id', (CAST(NULL AS STRING), 4)), ('page_location', ('https://developmentfinance.org/a', NULL))]),
    ('20261007', 'page_view', NULL, TRUE, STRUCT('No'), [('ga_session_id', (CAST(NULL AS STRING), 5)), ('page_location', ('https://developmentfinance.org/b', NULL))]),
    ('20261007', 'user_engagement', NULL, TRUE, STRUCT('No'), [('ga_session_id', (CAST(NULL AS STRING), 5)), ('page_location', ('https://developmentfinance.org/b', NULL))]),
    ('20261008', 'page_view', 'u1', TRUE, STRUCT('Yes'), [('ga_session_id', (CAST(NULL AS STRING), 3)), ('page_location', ('https://developmentfinance.org/a', NULL))])])
  )"

check ga4_daily \
    '{"day":"2026-10-05","active_users":5,"sessions":6,"page_views":7,"declined_page_views":null}
{"day":"2026-10-06","active_users":4,"sessions":4,"page_views":4,"declined_page_views":null}
{"day":"2026-10-07","active_users":2,"sessions":4,"page_views":6,"declined_page_views":2}
{"day":"2026-10-08","active_users":1,"sessions":1,"page_views":1,"declined_page_views":0}' \
    "$(view_rows ga4_daily 't.day' events=events history=history_daily)"

check ga4_pages_daily \
    '{"day":"2026-10-06","page_path":"/","page_views":3,"sessions":3,"declined_page_views":null}
{"day":"2026-10-07","page_path":"(not set)","page_views":0,"sessions":1,"declined_page_views":0}
{"day":"2026-10-07","page_path":"/","page_views":0,"sessions":1,"declined_page_views":0}
{"day":"2026-10-07","page_path":"/a","page_views":4,"sessions":3,"declined_page_views":1}
{"day":"2026-10-07","page_path":"/b","page_views":2,"sessions":1,"declined_page_views":1}
{"day":"2026-10-08","page_path":"/a","page_views":1,"sessions":1,"declined_page_views":0}' \
    "$(view_rows ga4_pages_daily 't.day, t.page_path' events=events history=history_pages)"

finish reporting_ga4.test.sh
