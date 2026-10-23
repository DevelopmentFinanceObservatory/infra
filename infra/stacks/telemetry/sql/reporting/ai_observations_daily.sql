-- The view dfo_reporting.ai_observations_daily, a Terraform template
-- (reporting_views.tf): Langfuse observations per UTC day of their start,
-- observation type, name, model, trace name and level, from ${observations},
-- the Langfuse export's observation rows, across every trace. It holds no
-- text and no id. errors counts the observations at level ERROR. Counts,
-- tokens and cost sum across rows. The latency quantiles are approximate
-- and do not combine across rows.
SELECT
  DATE(start_time) AS day,
  type,
  name,
  model,
  COUNT(*) AS observations,
  COUNTIF(level = 'ERROR') AS errors,
  APPROX_QUANTILES(latency_seconds, 100)[SAFE_OFFSET(50)] AS latency_p50_seconds,
  APPROX_QUANTILES(latency_seconds, 100)[SAFE_OFFSET(95)] AS latency_p95_seconds,
  SUM(input_tokens) AS input_tokens,
  SUM(output_tokens) AS output_tokens,
  SUM(total_cost_usd) AS cost_usd,
  trace_name,
  level,
  SUM(total_tokens) AS total_tokens
FROM `${observations}`
GROUP BY day, type, name, model, trace_name, level
