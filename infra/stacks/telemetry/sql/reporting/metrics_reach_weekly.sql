-- The view dfo_reporting.metrics_reach_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: iso_week x kind
-- (share, embed). Opens of shared or embedded artefacts by someone other than
-- their creator. The host where an artefact was opened is aggregated away;
-- hosts counts the distinct ones.
SELECT
  r.iso_week,
  r.kind,
  SUM(r.opens) AS opens,
  SUM(r.unknown_opens) AS unknown_opens,
  COUNT(DISTINCT r.host) AS hosts
FROM `${reach_weekly}` AS r
WHERE r.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
GROUP BY r.iso_week, r.kind
