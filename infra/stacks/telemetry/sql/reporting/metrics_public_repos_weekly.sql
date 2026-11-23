-- The view dfo_reporting.metrics_public_repos_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: iso_week. Public
-- repositories that declare the SDK or name the MCP endpoint, from the weekly
-- repository search.
SELECT
  p.iso_week,
  p.sdk_repos,
  p.sdk_new_repos,
  p.mcp_repos,
  p.mcp_new_repos,
  p.any_query_failed,
  p.any_capped,
  p.any_incomplete
FROM `${public_repos_weekly}` AS p
WHERE p.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
