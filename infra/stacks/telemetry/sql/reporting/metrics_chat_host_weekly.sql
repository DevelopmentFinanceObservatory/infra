-- The view dfo_reporting.metrics_chat_host_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: iso_week x host, a
-- chat-host client family in user_agent_families. Calls count when served as a
-- use. Chat-host calls reach DFO through the api and mcp surfaces, so
-- api_observed and mcp_observed say which surfaces observed the week in full;
-- a week with either false reads low. The mart has no row for a host-week with
-- no calls.
WITH observed AS (
  SELECT
    iso_week,
    LOGICAL_OR(surface = 'api' AND observed) AS api_observed,
    LOGICAL_OR(surface = 'mcp' AND observed) AS mcp_observed
  FROM `${int_surface_weeks_observed}`
  WHERE surface IN ('api', 'mcp')
  GROUP BY iso_week
)
SELECT
  h.iso_week,
  h.host,
  h.data_calls,
  h.indicators,
  COALESCE(o.api_observed, FALSE) AS api_observed,
  COALESCE(o.mcp_observed, FALSE) AS mcp_observed
FROM `${chat_host_weekly}` AS h
LEFT JOIN observed AS o
  ON o.iso_week = h.iso_week
WHERE h.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
