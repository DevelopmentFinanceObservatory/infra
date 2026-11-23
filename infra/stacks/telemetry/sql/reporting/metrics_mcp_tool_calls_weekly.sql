-- The view dfo_reporting.metrics_mcp_tool_calls_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: iso_week x tool.
-- Successful tool calls from outside callers, with shared servers' calls and
-- failed calls apart. Polls for pending answers are not counted. Complete
-- weeks only.
SELECT
  c.iso_week,
  c.tool,
  c.calls,
  c.callers,
  c.shared_server_calls,
  c.failed_calls
FROM `${mcp_tool_calls_weekly}` AS c
WHERE c.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
