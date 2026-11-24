-- The view dfo_reporting.ai_turns while var.analytics_dbt_schedule_enabled is
-- on, a Terraform template (reporting_views.tf): one row per AI assistant turn
-- from the Langfuse export, with no text and no id, as ${table} holds them.
-- The analytics repository's dbt model of the same name builds that table with
-- the rule ai_turns.sql applies when the switch is off.
SELECT
  day,
  started_at,
  session_sketch,
  latency_seconds,
  time_to_first_token_seconds,
  generations,
  tool_calls,
  input_tokens,
  output_tokens,
  cost_usd,
  errored,
  cached_input_tokens
FROM `${table}`
