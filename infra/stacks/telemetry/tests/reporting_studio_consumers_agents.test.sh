#!/usr/bin/env bash
# Tests sql/reporting/studio_turn_grades.sql, api_consumers_daily.sql,
# consumer_keys_daily.sql and declared_agent_requests_daily.sql against
# literal rows in the analytics marts' contracts (dbt/models/marts/models.yml
# in the analytics repository), each with a column the view must leave out.
# Not wired into CI. Run by hand after touching one of the views:
#   infra/stacks/telemetry/tests/reporting_studio_consumers_agents.test.sh [project]
#
# studio_turn_grades drops the trace ids and keeps an ungraded turn with null
# grade columns. api_consumers_daily counts three studio accounts on
# 2026-11-20, two of them external, and sums their uses, so the indicator one
# account used and another used too counts twice in indicator_uses; the
# address row stays its own group, and the sketch counts what consumers does.
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
    ('t2', 'w2', '2026-11-20 23:59:59+00', [('not_data_question', 1.0)], 'not_data_question', 'not_finance', FALSE, NULL, NULL, NULL)])
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

check studio_turn_grades \
    '{"day":"2026-11-20","started_at":"2026-11-20T10:00:00Z","final_grade":"P","in_population":true,"audience":"external","main_subject":"aid","question_topics":[{"topic_id":"aid","weight":0.75},{"topic_id":"debt","weight":0.25}],"finance_kind":"aid","asks_for_data":true}
{"day":"2026-11-20","started_at":"2026-11-20T23:59:59Z","final_grade":null,"in_population":null,"audience":null,"main_subject":"not_data_question","question_topics":[{"topic_id":"not_data_question","weight":1}],"finance_kind":"not_finance","asks_for_data":false}' \
    "$(view_rows studio_turn_grades 't.started_at' studio_turn_topics=turns)"

check api_consumers_daily \
    '{"day":"2026-11-20","surface":"studio","consumer_kind":"account","caller_class":"identified","audience":"external","consumers":2,"sketch_consumers":2,"indicator_uses":3,"spec_uses":2,"spec_fetches":4,"delivery_lines":5,"backfill_reads":0,"rows_served":110}
{"day":"2026-11-20","surface":"studio","consumer_kind":"account","caller_class":"identified","audience":"one_campaign","consumers":1,"sketch_consumers":1,"indicator_uses":1,"spec_uses":1,"spec_fetches":2,"delivery_lines":2,"backfill_reads":0,"rows_served":20}
{"day":"2026-11-20","surface":"studio","consumer_kind":"ip","caller_class":"address","audience":"unknown","consumers":1,"sketch_consumers":1,"indicator_uses":1,"spec_uses":1,"spec_fetches":1,"delivery_lines":1,"backfill_reads":1,"rows_served":5}' \
    "$(query_rows "SELECT TO_JSON_STRING(t) AS row FROM (
  SELECT * EXCEPT (consumers_sketch, indicator_uses, spec_uses, spec_fetches, delivery_lines, backfill_reads, rows_served),
    HLL_COUNT.EXTRACT(consumers_sketch) AS sketch_consumers,
    indicator_uses, spec_uses, spec_fetches, delivery_lines, backfill_reads, rows_served
  FROM ($(view_sql api_consumers_daily consumer_daily=consumers))
) AS t
ORDER BY t.consumer_kind, t.audience")"

check consumer_keys_daily \
    '{"day":"2026-11-20","key_kind":"ip","keys_seen":40,"returning_keys":12,"trailing_returning_keys":10.5,"trailing_returning_share":0.25,"keys_look_rotated":false}' \
    "$(view_rows consumer_keys_daily 't.day' consumer_key_persistence_daily=key_days)"

check declared_agent_requests_daily \
    '{"day":"2026-11-20","route":"/data/:id","kind":"page","declared_agent":"user_fetcher","declared_agent_name":"ChatGPT-User","status_class":2,"requests":7,"retrievals":6}' \
    "$(view_rows declared_agent_requests_daily 't.day' declared_agent_requests_daily=agents)"

finish reporting_studio_consumers_agents.test.sh
