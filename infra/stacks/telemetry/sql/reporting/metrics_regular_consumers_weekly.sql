-- The view dfo_reporting.metrics_regular_consumers_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: surface x iso_week
-- x caller_class x audience. The mart holds one row per consumer and leaves
-- pooled addresses out; counts are distinct on the consumer. A class and
-- audience appear on a surface from the first week they hold any row there, and
-- observed weeks after that with no regular read 0.
WITH observed AS (
  SELECT surface, iso_week, askers_partly_unnamed,
    weeks_observed_of_last_4, weeks_observed_of_last_8
  FROM `${int_surface_weeks_observed}`
  WHERE observed AND iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
),
classes AS (
  SELECT surface, caller_class, audience, MIN(iso_week) AS first_week
  FROM `${regular_consumers_weekly}`
  GROUP BY surface, caller_class, audience
),
counts AS (
  SELECT surface, iso_week, caller_class, audience,
    COUNT(DISTINCT IF(active_this_week, consumer, NULL)) AS active_consumers,
    COUNT(DISTINCT IF(is_regular_interim, consumer, NULL)) AS regular_2_of_4,
    COUNT(DISTINCT IF(is_regular, consumer, NULL)) AS regular_3_of_8
  FROM `${regular_consumers_weekly}`
  GROUP BY surface, iso_week, caller_class, audience
)
SELECT
  o.surface,
  o.iso_week,
  k.caller_class,
  k.audience,
  COALESCE(c.active_consumers, 0) AS active_consumers,
  COALESCE(c.regular_2_of_4, 0) AS regular_2_of_4,
  COALESCE(c.regular_3_of_8, 0) AS regular_3_of_8,
  o.weeks_observed_of_last_4,
  o.weeks_observed_of_last_8,
  o.askers_partly_unnamed
FROM observed AS o
JOIN classes AS k
  ON k.surface = o.surface AND o.iso_week >= k.first_week
LEFT JOIN counts AS c
  ON c.surface = o.surface AND c.iso_week = o.iso_week
  AND c.caller_class = k.caller_class AND c.audience = k.audience
