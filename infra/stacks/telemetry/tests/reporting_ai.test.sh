#!/usr/bin/env bash
# Tests sql/reporting/ai_turns.sql and ai_observations_daily.sql against
# literal rows in the Langfuse export's observations schema (dfo-ai
# services/harness/src/harness/langfuse_export.py). Not wired into CI. Run by
# hand after touching either view:
#   infra/stacks/telemetry/tests/reporting_ai.test.sh [project]
#
# Traces:
#   t1, a turn in session sess-1: a root span named turn, two generations on
#     two models, the second at ERROR and ending after the span, and a tool
#     call. Its start and latency are the turn span's, and its time to first
#     token runs from the span's start to the first generation's first token.
#   t2, a turn in sess-1 whose turn span was not exported, so it runs from
#     its generation's start to its tool call's end.
#   t3, a turn in sess-2 still running, with no end time.
#   t4, a studio.refresh trace with no session, which is not a turn.
#   t5 and t6, studio.refresh traces on two later days holding fetch tool
#     calls: three of 1 second on the first day and one of 9 on the second.
#     The pooled median is 1, and the mean of the two daily medians is 5.
# o2 records 40 cached input tokens, o5 records 0 and the rest record none, so
# the cached_input_tokens sums are 40, 0 and NULL.
# Each turn's session sketch counts one session, and merged over all turns
# they count 2.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"

SOURCES="WITH
  observations AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<id STRING, trace_id STRING, parent_observation_id STRING,
      is_root_observation BOOL, session_id STRING, trace_name STRING, name STRING, type STRING,
      level STRING, environment STRING, model STRING, start_time TIMESTAMP, end_time TIMESTAMP,
      latency_seconds FLOAT64, time_to_first_token_seconds FLOAT64, input_tokens INT64,
      output_tokens INT64, total_tokens INT64, input_cost_usd FLOAT64, output_cost_usd FLOAT64,
      total_cost_usd FLOAT64, cached_input_tokens INT64>>[
    ('o1', 't1', NULL, TRUE, 'sess-1', 'turn', 'turn', 'SPAN', 'DEFAULT', 'dfo-prod-ai', NULL,
      '2026-10-05 10:00:00+00', '2026-10-05 10:00:05+00', 5.0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    ('o2', 't1', 'o1', FALSE, 'sess-1', 'turn', 'orchestrate', 'GENERATION', 'DEFAULT', 'dfo-prod-ai', 'gemini-3.8-flash',
      '2026-10-05 10:00:01+00', '2026-10-05 10:00:03+00', 2.0, 0.5, 100, 20, 120, 0.25, 0.25, 0.5, 40),
    ('o3', 't1', 'o1', FALSE, 'sess-1', 'turn', 'search', 'TOOL', 'DEFAULT', 'dfo-prod-ai', NULL,
      '2026-10-05 10:00:02+00', '2026-10-05 10:00:02.500+00', 0.5, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    ('o4', 't1', 'o1', FALSE, 'sess-1', 'turn', 'bind', 'GENERATION', 'ERROR', 'dfo-prod-ai', 'gemini-3.5-flash-lite',
      '2026-10-05 10:00:03+00', '2026-10-05 10:00:06+00', 3.0, 1.0, 10, 5, 15, 0.125, 0.125, 0.25, NULL),
    ('o8', 't2', 'o5', FALSE, 'sess-1', 'turn', 'search', 'TOOL', 'DEFAULT', 'dfo-prod-ai', NULL,
      '2026-10-06 00:00:00+00', '2026-10-06 00:00:04+00', 4.0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    ('o5', 't2', NULL, TRUE, 'sess-1', 'turn', 'orchestrate', 'GENERATION', 'DEFAULT', 'dfo-prod-ai', 'gemini-3.8-flash',
      '2026-10-05 23:59:59+00', '2026-10-06 00:00:01+00', 2.0, 0.5, 1, 1, 2, 0.0625, 0.0625, 0.125, 0),
    ('o6', 't3', NULL, TRUE, 'sess-2', 'turn', 'turn', 'SPAN', 'DEFAULT', 'dfo-prod-ai', NULL,
      '2026-10-06 08:00:00+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    ('o7', 't4', NULL, TRUE, NULL, 'studio.refresh', 'studio.refresh', 'SPAN', 'DEFAULT', 'dfo-prod-ai', NULL,
      '2026-10-06 09:00:00+00', '2026-10-06 09:00:01+00', 1.0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    ('o9', 't5', NULL, TRUE, NULL, 'studio.refresh', 'fetch', 'TOOL', 'DEFAULT', 'dfo-prod-ai', NULL,
      '2026-10-07 09:00:00+00', '2026-10-07 09:00:01+00', 1.0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    ('o10', 't5', 'o9', FALSE, NULL, 'studio.refresh', 'fetch', 'TOOL', 'DEFAULT', 'dfo-prod-ai', NULL,
      '2026-10-07 09:00:02+00', '2026-10-07 09:00:03+00', 1.0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    ('o11', 't5', 'o9', FALSE, NULL, 'studio.refresh', 'fetch', 'TOOL', 'DEFAULT', 'dfo-prod-ai', NULL,
      '2026-10-07 09:00:04+00', '2026-10-07 09:00:05+00', 1.0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    ('o12', 't6', NULL, TRUE, NULL, 'studio.refresh', 'fetch', 'TOOL', 'DEFAULT', 'dfo-prod-ai', NULL,
      '2026-10-08 09:00:00+00', '2026-10-08 09:00:09+00', 9.0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)])
  )"

TURNS="$(view_sql ai_turns observations=observations)"

check ai_turns \
    '{"day":"2026-10-05","started_at":"2026-10-05T10:00:00Z","session_sketch":1,"latency_seconds":5,"time_to_first_token_seconds":1.5,"generations":2,"tool_calls":1,"input_tokens":110,"output_tokens":25,"cost_usd":0.75,"errored":true,"cached_input_tokens":40}
{"day":"2026-10-05","started_at":"2026-10-05T23:59:59Z","session_sketch":1,"latency_seconds":5,"time_to_first_token_seconds":0.5,"generations":1,"tool_calls":1,"input_tokens":1,"output_tokens":1,"cost_usd":0.125,"errored":false,"cached_input_tokens":0}
{"day":"2026-10-06","started_at":"2026-10-06T08:00:00Z","session_sketch":1,"latency_seconds":null,"time_to_first_token_seconds":null,"generations":0,"tool_calls":0,"input_tokens":null,"output_tokens":null,"cost_usd":null,"errored":false,"cached_input_tokens":null}' \
    "$(query_rows "SELECT TO_JSON_STRING(t) AS row FROM (
  SELECT * REPLACE (HLL_COUNT.EXTRACT(session_sketch) AS session_sketch) FROM ($TURNS)
) AS t
ORDER BY t.started_at")"

check 'ai_turns sessions merged over every turn' \
    '{"turns":3,"sessions":2}' \
    "$(query_rows "SELECT TO_JSON_STRING(t) AS row FROM (
  SELECT COUNT(*) AS turns, HLL_COUNT.MERGE(session_sketch) AS sessions FROM ($TURNS)
) AS t")"

OBSERVATIONS="$(view_sql ai_observations_daily observations=observations)"

# The sketch column is bytes, so this check reads it as its median, which
# equals latency_p50_seconds and is null where no observation has a latency.
check ai_observations_daily \
    '{"day":"2026-10-05","type":"GENERATION","name":"bind","model":"gemini-3.5-flash-lite","observations":1,"errors":1,"latency_p50_seconds":3,"latency_p95_seconds":3,"input_tokens":10,"output_tokens":5,"cost_usd":0.25,"trace_name":"turn","level":"ERROR","total_tokens":15,"latency_sketch":3,"cached_input_tokens":null}
{"day":"2026-10-05","type":"GENERATION","name":"orchestrate","model":"gemini-3.8-flash","observations":2,"errors":0,"latency_p50_seconds":2,"latency_p95_seconds":2,"input_tokens":101,"output_tokens":21,"cost_usd":0.625,"trace_name":"turn","level":"DEFAULT","total_tokens":122,"latency_sketch":2,"cached_input_tokens":40}
{"day":"2026-10-05","type":"SPAN","name":"turn","model":null,"observations":1,"errors":0,"latency_p50_seconds":5,"latency_p95_seconds":5,"input_tokens":null,"output_tokens":null,"cost_usd":null,"trace_name":"turn","level":"DEFAULT","total_tokens":null,"latency_sketch":5,"cached_input_tokens":null}
{"day":"2026-10-05","type":"TOOL","name":"search","model":null,"observations":1,"errors":0,"latency_p50_seconds":0.5,"latency_p95_seconds":0.5,"input_tokens":null,"output_tokens":null,"cost_usd":null,"trace_name":"turn","level":"DEFAULT","total_tokens":null,"latency_sketch":0.5,"cached_input_tokens":null}
{"day":"2026-10-06","type":"SPAN","name":"studio.refresh","model":null,"observations":1,"errors":0,"latency_p50_seconds":1,"latency_p95_seconds":1,"input_tokens":null,"output_tokens":null,"cost_usd":null,"trace_name":"studio.refresh","level":"DEFAULT","total_tokens":null,"latency_sketch":1,"cached_input_tokens":null}
{"day":"2026-10-06","type":"SPAN","name":"turn","model":null,"observations":1,"errors":0,"latency_p50_seconds":null,"latency_p95_seconds":null,"input_tokens":null,"output_tokens":null,"cost_usd":null,"trace_name":"turn","level":"DEFAULT","total_tokens":null,"latency_sketch":null,"cached_input_tokens":null}
{"day":"2026-10-06","type":"TOOL","name":"search","model":null,"observations":1,"errors":0,"latency_p50_seconds":4,"latency_p95_seconds":4,"input_tokens":null,"output_tokens":null,"cost_usd":null,"trace_name":"turn","level":"DEFAULT","total_tokens":null,"latency_sketch":4,"cached_input_tokens":null}
{"day":"2026-10-07","type":"TOOL","name":"fetch","model":null,"observations":3,"errors":0,"latency_p50_seconds":1,"latency_p95_seconds":1,"input_tokens":null,"output_tokens":null,"cost_usd":null,"trace_name":"studio.refresh","level":"DEFAULT","total_tokens":null,"latency_sketch":1,"cached_input_tokens":null}
{"day":"2026-10-08","type":"TOOL","name":"fetch","model":null,"observations":1,"errors":0,"latency_p50_seconds":9,"latency_p95_seconds":9,"input_tokens":null,"output_tokens":null,"cost_usd":null,"trace_name":"studio.refresh","level":"DEFAULT","total_tokens":null,"latency_sketch":9,"cached_input_tokens":null}' \
    "$(query_rows "SELECT TO_JSON_STRING(t) AS row FROM (
  SELECT * REPLACE (KLL_QUANTILES.EXTRACT_POINT_FLOAT64(latency_sketch, 0.5) AS latency_sketch)
  FROM ($OBSERVATIONS)
) AS t
ORDER BY t.day, t.type, t.name")"

check 'ai_observations_daily latency merged over two days of one name' \
    '{"observations":4,"p50":1,"mean_of_daily_p50":5}' \
    "$(query_rows "SELECT TO_JSON_STRING(t) AS row FROM (
  SELECT
    SUM(observations) AS observations,
    KLL_QUANTILES.MERGE_POINT_FLOAT64(latency_sketch, 0.5) AS p50,
    AVG(latency_p50_seconds) AS mean_of_daily_p50
  FROM ($OBSERVATIONS)
  WHERE name = 'fetch'
) AS t")"

finish reporting_ai.test.sh
