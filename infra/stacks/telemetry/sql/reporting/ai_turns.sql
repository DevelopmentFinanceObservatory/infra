-- The view dfo_reporting.ai_turns, a Terraform template
-- (reporting_views.tf): one row per AI assistant turn, a Langfuse trace
-- named turn, from ${observations}, the Langfuse export's observation rows.
-- It holds no text and no id.
--
-- A turn has one of two shapes. A segmented turn runs as one or more root
-- observations named turn.segment, one per request that worked on it, with a
-- zero-duration root turn.pause at each pause, and ends with a zero-duration
-- root observation named turn that common.telemetry.record_turn_outcome
-- opens and ends at the close. Its started_at is the earliest turn.segment
-- start, and its latency_seconds runs from there to the start of the turn
-- observation, so it includes any pause. A segmented turn with no turn
-- observation yet is paused, and runs to its last observation's end. An
-- unsegmented turn has one span named turn, which
-- common.telemetry.start_turn_span opens, preferring a root one, and
-- started_at and latency_seconds are the span's. A trace of that shape
-- whose turn span was not exported runs from its first observation's start
-- to its last one's end. day is the UTC date of started_at.
--
-- time_to_first_token_seconds is the turn span's when it has one, and
-- otherwise runs from started_at to the first token of the turn's first
-- generation that records one. Counts, tokens and cost cover every
-- observation of the trace, and errored is true when any of them is at level
-- ERROR. cached_input_tokens is the part of input_tokens served from the
-- model's cache, NULL when no observation of the trace records one.
-- tool_calls counts observations of type TOOL. session_sketch is an HLL++
-- sketch of the turn's Langfuse session id, so HLL_COUNT.MERGE over any
-- range of rows counts conversations while the session id itself stays out.
SELECT
  DATE(started_at) AS day,
  started_at,
  session_sketch,
  CASE
    WHEN segment_start IS NOT NULL AND turn_span IS NOT NULL
      THEN TIMESTAMP_DIFF(turn_span.start_time, started_at, MICROSECOND) / 1e6
    WHEN turn_span IS NULL
      THEN TIMESTAMP_DIFF(last_end, started_at, MICROSECOND) / 1e6
    ELSE turn_span.latency_seconds
  END AS latency_seconds,
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
  errored,
  cached_input_tokens
FROM (
  SELECT
    *,
    COALESCE(segment_start, turn_span.start_time, first_start) AS started_at
  FROM (
    SELECT
      ARRAY_AGG(
        IF(name = 'turn', STRUCT(start_time, latency_seconds, time_to_first_token_seconds), NULL)
        IGNORE NULLS
        ORDER BY IFNULL(is_root_observation, parent_observation_id IS NULL) DESC, start_time
        LIMIT 1
      )[SAFE_OFFSET(0)] AS turn_span,
      MIN(IF(name = 'turn.segment', start_time, NULL)) AS segment_start,
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
      LOGICAL_OR(level = 'ERROR') AS errored,
      SUM(cached_input_tokens) AS cached_input_tokens
    FROM `${observations}`
    WHERE trace_name = 'turn'
    GROUP BY trace_id
  )
)
