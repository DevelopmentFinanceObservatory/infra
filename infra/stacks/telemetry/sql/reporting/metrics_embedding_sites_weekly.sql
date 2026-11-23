-- The view dfo_reporting.metrics_embedding_sites_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: iso_week. Sites
-- that embed DFO, counted, never named.
SELECT
  e.iso_week,
  COUNT(DISTINCT e.host) AS sites,
  COUNT(DISTINCT IF(e.is_regular, e.host, NULL)) AS regular_sites,
  SUM(e.opens_this_week) AS opens
FROM `${embedding_sites_weekly}` AS e
WHERE e.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
GROUP BY e.iso_week
