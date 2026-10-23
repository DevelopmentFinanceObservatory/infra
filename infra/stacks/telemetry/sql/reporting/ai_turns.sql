-- The view dfo_reporting.ai_turns, a Terraform template
-- (reporting_views.tf): one row per AI assistant turn, a Langfuse trace
-- named turn, from ${observations}, the Langfuse export's observation rows.
-- It holds no text and no id.
--
-- started_at, day (UTC) and latency_seconds are those of the turn's span
-- named turn, which common.telemetry.start_turn_span opens, preferring a
-- root one. A trace whose turn span was not exported runs from its first
-- observation's start to its last one's end. time_to_first_token_seconds is
-- the turn span's when it has one, and otherwise runs from started_at to the
-- first token of the turn's first generation that records one. Counts,
-- tokens and cost cover every observation of the trace, and errored is true
-- when any of them is at level ERROR. tool_calls counts observations of type
-- TOOL. session_sketch is an HLL++ sketch of the turn's Langfuse session id,
-- so HLL_COUNT.MERGE over any range of rows counts conversations while the
-- session id itself stays out.
SELECT
  DATE(started_at) AS day,
  started_at,
  session_sketch,
  IF(
    turn_span IS NULL,
    TIMESTAMP_DIFF(last_end, started_at, MICROSECOND) / 1e6,
    turn_span.latency_seconds
  ) AS latency_seconds,
  IFNULL(
    turn_span.time_to_first_token_seconds,
    TIMESTAMP_DIFF(first_generation.start_time, started_at, MICROSECOND) / 1e6
      + first_generation.time_to_first_token_seconds
  ) AS time_to_first_token_seconds,
  generations,
  tool_calls,
  input_tokens,
  output_tokens,
  cost_usd,
  errored
FROM (
  SELECT
    *,
    IFNULL(turn_span.start_time, first_start) AS started_at
  FROM (
    SELECT
      ARRAY_AGG(
        IF(name = 'turn', STRUCT(start_time, latency_seconds, time_to_first_token_seconds), NULL)
        IGNORE NULLS
        ORDER BY IFNULL(is_root_observation, parent_observation_id IS NULL) DESC, start_time
        LIMIT 1
      )[SAFE_OFFSET(0)] AS turn_span,
      MIN(start_time) AS first_start,
      MAX(end_time) AS last_end,
      ARRAY_AGG(
        IF(
          type = 'GENERATION' AND time_to_first_token_seconds IS NOT NULL,
          STRUCT(start_time, time_to_first_token_seconds),
          NULL
        ) IGNORE NULLS
        ORDER BY start_time
        LIMIT 1
      )[SAFE_OFFSET(0)] AS first_generation,
      HLL_COUNT.INIT(session_id, 14) AS session_sketch,
      COUNTIF(type = 'GENERATION') AS generations,
      COUNTIF(type = 'TOOL') AS tool_calls,
      SUM(input_tokens) AS input_tokens,
      SUM(output_tokens) AS output_tokens,
      SUM(total_cost_usd) AS cost_usd,
      LOGICAL_OR(level = 'ERROR') AS errored
    FROM `${observations}`
    WHERE trace_name = 'turn'
    GROUP BY trace_id
  )
)
