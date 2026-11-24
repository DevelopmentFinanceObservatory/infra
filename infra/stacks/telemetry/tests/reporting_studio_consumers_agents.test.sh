#!/usr/bin/env bash
# Tests sql/reporting/studio_turn_grades_daily.sql,
# studio_question_topics_daily.sql, api_consumers_daily.sql,
# consumer_keys_daily.sql and declared_agent_requests_daily.sql against
# literal rows in the analytics marts' contracts (dbt/models/marts/models.yml
# in the analytics repository), each with a column the view must leave out.
# Not wired into CI. Run by hand after touching one of the views:
#   infra/stacks/telemetry/tests/reporting_studio_consumers_agents.test.sh [project]
#
# Four turns on 2026-11-20: two graded P that share a row, an ungraded one with
# null grade columns, and a test turn graded T outside the population. The
# topics view counts the turns naming each topic and sums its weights.
# api_consumers_daily counts three studio accounts on 2026-11-20, two of them
# external, and sums their uses, so the indicator one account used and another
# used too counts twice in indicator_uses; the address row stays its own group.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"

SOURCES="WITH
  turns AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<trace_id STRING, wire_trace_id STRING, turn_started_at TIMESTAMP,
      question_topics ARRAY<STRUCT<topic_id STRING, weight FLOAT64>>, main_subject STRING,
      finance_kind STRING, asks_for_data BOOL, final_grade STRING, in_population BOOL, audience STRING>>[
    ('t1', 'w1', '2026-11-20 10:00:00+00', [('aid', 0.75), ('debt', 0.25)], 'aid', 'aid', TRUE, 'P', TRUE, 'external'),
    ('t2', 'w2', '2026-11-20 23:59:59+00', [('not_data_question', 1.0)], 'not_data_question', 'not_finance', FALSE, NULL, NULL, NULL),
    ('t3', 'w3', '2026-11-20 11:00:00+00', [('debt', 1.0)], 'debt', 'debt', TRUE, 'T', FALSE, 'one_campaign'),
    ('t4', 'w4', '2026-11-20 12:00:00+00', [('aid', 1.0)], 'aid', 'aid', TRUE, 'P', TRUE, 'external')])
  ),
  consumers AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<day DATE, surface STRING, consumer STRING, consumer_kind STRING,
      caller_class STRING, audience STRING, indicators_used INT64, specs_used INT64, specs_fetched INT64,
      delivery_lines INT64, backfill_reads INT64, rows_served INT64>>[
    ('2026-11-20', 'studio', 'account:a1', 'account', 'identified', 'external', 2, 1, 3, 4, 0, 100),
    ('2026-11-20', 'studio', 'account:a2', 'account', 'identified', 'external', 1, 1, 1, 1, 0, 10),
    ('2026-11-20', 'studio', 'account:a3', 'account', 'identified', 'one_campaign', 1, 1, 2, 2, 0, 20),
    ('2026-11-20', 'studio', 'ip:x1', 'ip', 'address', 'unknown', 1, 1, 1, 1, 1, 5)])
  ),
  key_days AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<day DATE, key_kind STRING, keys_seen INT64, returning_keys INT64,
      trailing_returning_keys FLOAT64, trailing_returning_share FLOAT64, keys_look_rotated BOOL, extra STRING>>[
    ('2026-11-20', 'ip', 40, 12, 10.5, 0.25, FALSE, 'not selected')])
  ),
  agents AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<day DATE, route STRING, kind STRING, declared_agent STRING,
      declared_agent_name STRING, status_class INT64, requests INT64, retrievals INT64, extra STRING>>[
    ('2026-11-20', '/data/:id', 'page', 'user_fetcher', 'ChatGPT-User', 2, 7, 6, 'not selected')])
  )"

check studio_turn_grades_daily \
    '{"day":"2026-11-20","final_grade":null,"in_population":null,"audience":null,"main_subject":"not_data_question","finance_kind":"not_finance","asks_for_data":false,"turns":1}
{"day":"2026-11-20","final_grade":"P","in_population":true,"audience":"external","main_subject":"aid","finance_kind":"aid","asks_for_data":true,"turns":2}
{"day":"2026-11-20","final_grade":"T","in_population":false,"audience":"one_campaign","main_subject":"debt","finance_kind":"debt","asks_for_data":true,"turns":1}' \
    "$(view_rows studio_turn_grades_daily 't.final_grade' studio_turn_topics=turns)"

check studio_question_topics_daily \
    '{"day":"2026-11-20","in_population":null,"audience":null,"topic_id":"not_data_question","turns":1,"weight":1}
{"day":"2026-11-20","in_population":false,"audience":"one_campaign","topic_id":"debt","turns":1,"weight":1}
{"day":"2026-11-20","in_population":true,"audience":"external","topic_id":"aid","turns":2,"weight":1.75}
{"day":"2026-11-20","in_population":true,"audience":"external","topic_id":"debt","turns":1,"weight":0.25}' \
    "$(view_rows studio_question_topics_daily 't.in_population, t.topic_id' studio_turn_topics=turns)"

check api_consumers_daily \
    '{"day":"2026-11-20","surface":"studio","consumer_kind":"account","caller_class":"identified","audience":"external","consumers":2,"indicator_uses":3,"spec_uses":2,"spec_fetches":4,"delivery_lines":5,"backfill_reads":0,"rows_served":110}
{"day":"2026-11-20","surface":"studio","consumer_kind":"account","caller_class":"identified","audience":"one_campaign","consumers":1,"indicator_uses":1,"spec_uses":1,"spec_fetches":2,"delivery_lines":2,"backfill_reads":0,"rows_served":20}
{"day":"2026-11-20","surface":"studio","consumer_kind":"ip","caller_class":"address","audience":"unknown","consumers":1,"indicator_uses":1,"spec_uses":1,"spec_fetches":1,"delivery_lines":1,"backfill_reads":1,"rows_served":5}' \
    "$(view_rows api_consumers_daily 't.consumer_kind, t.audience' consumer_daily=consumers)"

check consumer_keys_daily \
    '{"day":"2026-11-20","key_kind":"ip","keys_seen":40,"returning_keys":12,"trailing_returning_keys":10.5,"trailing_returning_share":0.25,"keys_look_rotated":false}' \
    "$(view_rows consumer_keys_daily 't.day' consumer_key_persistence_daily=key_days)"

check declared_agent_requests_daily \
    '{"day":"2026-11-20","route":"/data/:id","kind":"page","declared_agent":"user_fetcher","declared_agent_name":"ChatGPT-User","status_class":2,"requests":7,"retrievals":6}' \
    "$(view_rows declared_agent_requests_daily 't.day' declared_agent_requests_daily=agents)"

finish reporting_studio_consumers_agents.test.sh
