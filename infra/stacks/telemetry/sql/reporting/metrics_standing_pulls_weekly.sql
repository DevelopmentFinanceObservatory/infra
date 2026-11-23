-- The view dfo_reporting.metrics_standing_pulls_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: surface x iso_week
-- x consumer_class. A standing pull is the same request made in 4 of the last
-- 8 weeks.
SELECT
  s.surface,
  s.iso_week,
  s.consumer_class,
  s.standing_pull_consumers,
  s.standing_pulls,
  s.weeks_observed_of_last_8
FROM `${standing_pulls_weekly}` AS s
JOIN `${int_surface_weeks_observed}` AS o
  ON o.surface = s.surface AND o.iso_week = s.iso_week
WHERE o.observed AND s.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
