-- The view dfo_reporting.ai_observations_daily once
-- var.reporting_marts_cutover is on, a Terraform template
-- (reporting_views.tf): Langfuse observations per UTC day, type, name, model,
-- trace name and level, with no text and no id, as ${table} holds them. The
-- analytics repository's dbt model of the same name builds that table with the
-- rule ai_observations_daily.sql applies while the cutover is off.
SELECT
  day,
  type,
  name,
  model,
  observations,
  errors,
  latency_p50_seconds,
  latency_p95_seconds,
  input_tokens,
  output_tokens,
  cost_usd,
  trace_name,
  level,
  total_tokens,
  latency_sketch,
  cached_input_tokens
FROM `${table}`
