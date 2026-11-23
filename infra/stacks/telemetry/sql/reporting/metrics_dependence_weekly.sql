-- The view dfo_reporting.metrics_dependence_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: surface x iso_week
-- x caller_class x audience. The mart is already aggregated and leaves pooled
-- addresses out; shares do not combine across rows.
SELECT
  d.surface,
  d.iso_week,
  d.caller_class,
  d.audience,
  d.consumers,
  d.regular_consumers_interim AS regular_2_of_4,
  d.regular_consumers AS regular_3_of_8,
  d.indicator_uses,
  d.top_ten_uses_share,
  d.regular_interim_uses_share AS regular_2_of_4_uses_share,
  d.regular_uses_share AS regular_3_of_8_uses_share,
  d.askers_partly_unnamed
FROM `${dependence_weekly}` AS d
JOIN `${int_surface_weeks_observed}` AS o
  ON o.surface = d.surface AND o.iso_week = d.iso_week
WHERE o.observed AND d.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
