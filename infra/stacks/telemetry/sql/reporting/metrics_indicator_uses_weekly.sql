-- The view dfo_reporting.metrics_indicator_uses_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: surface x iso_week
-- x kind x caller_class x audience. An indicator use is one consumer using one
-- indicator in one week, whatever the client, so indicator_uses counts distinct
-- (consumer, indicator) pairs. On pooled rows consumers is null and addresses counts the distinct pool
-- addresses.
SELECT
  u.surface,
  u.iso_week,
  u.kind,
  u.caller_class,
  u.audience,
  IF(u.caller_class = 'pooled', NULL, COUNT(DISTINCT u.consumer)) AS consumers,
  IF(u.caller_class = 'pooled', COUNT(DISTINCT u.consumer), NULL) AS addresses,
  COUNT(DISTINCT CONCAT(u.consumer, '|', u.indicator)) AS indicator_uses,
  COUNT(DISTINCT u.indicator) AS indicators
FROM `${indicator_uses_weekly}` AS u
WHERE u.observed AND u.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
GROUP BY u.surface, u.iso_week, u.kind, u.caller_class, u.audience
