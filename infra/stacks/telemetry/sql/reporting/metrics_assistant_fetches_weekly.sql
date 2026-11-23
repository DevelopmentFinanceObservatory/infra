-- The view dfo_reporting.metrics_assistant_fetches_weekly, a Terraform
-- template (reporting_views.tf) over the analytics dbt marts. Grain: iso_week
-- x agent_name x kind (page, api). Requests from agents that fetch for a
-- person and name themselves. Read from website request logs, so a week counts
-- when the website surface observed it.
SELECT
  a.iso_week,
  a.agent_name,
  a.kind,
  a.requests,
  a.retrievals
FROM `${assistant_fetches_weekly}` AS a
JOIN `${int_surface_weeks_observed}` AS o
  ON o.surface = 'website' AND o.iso_week = a.iso_week
WHERE o.observed AND a.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
