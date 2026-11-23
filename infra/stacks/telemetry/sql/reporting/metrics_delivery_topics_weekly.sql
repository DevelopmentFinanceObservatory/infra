-- The view dfo_reporting.metrics_delivery_topics_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: surface x iso_week
-- x axis x topic_id. Dataset reads split across their spec's topics by weight,
-- summed from days to complete weeks. Reads on surfaces with no observation
-- mark (unknown, direct) are left out.
SELECT
  d.surface,
  DATE_TRUNC(d.day, ISOWEEK) AS iso_week,
  d.axis,
  d.topic_id,
  ANY_VALUE(COALESCE(t.name, d.topic_id)) AS topic_name,
  SUM(d.deliveries) AS deliveries
FROM `${delivery_topics_daily}` AS d
JOIN `${int_surface_weeks_observed}` AS o
  ON o.surface = d.surface AND o.iso_week = DATE_TRUNC(d.day, ISOWEEK)
LEFT JOIN `${topic_taxonomy}` AS t
  ON t.axis = d.axis AND t.topic_id = d.topic_id
WHERE o.observed AND d.day < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
GROUP BY d.surface, iso_week, d.axis, d.topic_id
