-- The view dfo_reporting.metrics_indicator_uses_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: surface x iso_week
-- x kind x client_family. client_family 'all' is the surface total; the other
-- rows split it by client (Claude Code, Codex, dfo-ts, curl and so on,
-- 'unknown' where the client is not recognised). Distinct counts are computed
-- at both grains, so the family rows do not add up to the 'all' row when one
-- key uses two clients.
SELECT
  u.surface,
  u.iso_week,
  u.kind,
  IF(GROUPING(u.client_family) = 1, 'all', COALESCE(u.client_family, 'unknown')) AS client_family,
  COUNT(DISTINCT u.consumer) AS consumers,
  COUNT(DISTINCT CONCAT(u.consumer, '|', u.indicator)) AS indicator_uses,
  COUNT(DISTINCT u.indicator) AS indicators
FROM `${indicator_uses_weekly}` AS u
JOIN `${int_surface_weeks_observed}` AS o
  ON o.surface = u.surface AND o.iso_week = u.iso_week
WHERE o.observed AND u.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
GROUP BY GROUPING SETS (
  (u.surface, u.iso_week, u.kind),
  (u.surface, u.iso_week, u.kind, u.client_family)
)
