-- The view dfo_reporting.metrics_chat_host_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: iso_week x host
-- (ChatGPT, Claude.ai, Gemini). Chat-host calls reach DFO through the api and
-- mcp surfaces, so a week counts only when both observed it. The mart has no
-- row for a host-week with no calls.
WITH observed AS (
  SELECT iso_week
  FROM `${int_surface_weeks_observed}`
  WHERE observed AND surface IN ('api', 'mcp')
  GROUP BY iso_week
  HAVING COUNT(DISTINCT surface) = 2
)
SELECT
  h.iso_week,
  h.host,
  h.data_calls,
  h.indicators
FROM `${chat_host_weekly}` AS h
JOIN observed AS o
  ON o.iso_week = h.iso_week
WHERE h.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
