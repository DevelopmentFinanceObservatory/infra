-- The view dfo_reporting.metrics_assistant_pages_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: iso_week x
-- agent_name x route. Pages that assistants fetched for a person's question,
-- by route template. Complete weeks only.
SELECT
  p.iso_week,
  p.agent_name,
  p.route,
  p.retrievals
FROM `${assistant_fetches_by_page_weekly}` AS p
WHERE p.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
