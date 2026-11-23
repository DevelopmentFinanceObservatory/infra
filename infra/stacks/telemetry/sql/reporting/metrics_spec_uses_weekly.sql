-- The view dfo_reporting.metrics_spec_uses_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: surface x iso_week
-- x kind (use, or fetched in Studio). A dataset use is one consumer using one
-- spec in one week, so dataset_uses counts distinct (consumer, spec) pairs.
SELECT
  u.surface,
  u.iso_week,
  u.kind,
  COUNT(DISTINCT u.consumer) AS consumers,
  COUNT(DISTINCT CONCAT(u.consumer, '|', u.spec_id)) AS dataset_uses,
  COUNT(DISTINCT u.spec_id) AS specs
FROM `${spec_uses_weekly}` AS u
JOIN `${int_surface_weeks_observed}` AS o
  ON o.surface = u.surface AND o.iso_week = u.iso_week
WHERE o.observed AND u.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
GROUP BY u.surface, u.iso_week, u.kind
