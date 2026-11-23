-- The view dfo_reporting.metrics_consumer_cohorts_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: surface x
-- cohort_week x caller_class x audience. A cohort is the keys first active on a
-- surface in that week; pooled addresses join none. The mart leaves a return
-- null until the surface has observed the week it falls in. A rate is retained
-- over cohort size within one caller class; in the address class a changed
-- address counts as a departure and several people behind one address count as
-- one, so read it beside the identified rows.
SELECT
  c.surface,
  c.cohort_week,
  c.caller_class,
  c.audience,
  c.cohort_size,
  c.retained_week_4,
  c.retention_week_4,
  c.retained_week_8,
  c.retention_week_8,
  c.retained_week_12,
  c.retention_week_12,
  c.askers_partly_unnamed
FROM `${consumer_cohorts_weekly}` AS c
JOIN `${int_surface_weeks_observed}` AS o
  ON o.surface = c.surface AND o.iso_week = c.cohort_week
WHERE o.observed AND c.cohort_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
