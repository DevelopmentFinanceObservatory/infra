-- The view dfo_reporting.metrics_crawler_reads_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: iso_week x
-- agent_name x kind (page, api, rsc). Requests from self-declared search and
-- training crawlers, observed as the website.
SELECT
  c.iso_week,
  c.agent_name,
  c.kind,
  c.requests,
  c.retrievals
FROM `${crawler_reads_weekly}` AS c
JOIN `${int_surface_weeks_observed}` AS o
  ON o.surface = 'website' AND o.iso_week = c.iso_week
WHERE o.observed AND c.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
