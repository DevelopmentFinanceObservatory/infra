-- The view dfo_reporting.metrics_indicator_uses_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: surface x iso_week
-- x kind x caller_class x audience. An indicator use is one consumer using one
-- indicator in one week, whatever the client, so indicator_uses counts distinct
-- (consumer, indicator) pairs. On pooled rows consumers counts pool addresses.
SELECT
  u.surface,
  u.iso_week,
  u.kind,
  u.caller_class,
  u.audience,
  COUNT(DISTINCT u.consumer) AS consumers,
  COUNT(DISTINCT CONCAT(u.consumer, '|', u.indicator)) AS indicator_uses,
  COUNT(DISTINCT u.indicator) AS indicators
FROM `${indicator_uses_weekly}` AS u
JOIN `${int_surface_weeks_observed}` AS o
  ON o.surface = u.surface AND o.iso_week = u.iso_week
WHERE o.observed AND u.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
GROUP BY u.surface, u.iso_week, u.kind, u.caller_class, u.audience
