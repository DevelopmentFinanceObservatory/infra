-- The view dfo_reporting.metrics_embedding_sites_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: iso_week. Sites
-- that embed DFO; the view holds no host names. A site counts in a week when it
-- opened at least once.
SELECT
  e.iso_week,
  COUNT(DISTINCT IF(e.opens_this_week > 0, e.host, NULL)) AS sites,
  COUNT(DISTINCT IF(e.is_regular, e.host, NULL)) AS regular_sites,
  SUM(e.opens_this_week) AS opens
FROM `${embedding_sites_weekly}` AS e
WHERE e.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
GROUP BY e.iso_week
