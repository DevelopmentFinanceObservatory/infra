-- The view dfo_reporting.metrics_topic_callers_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: iso_week x surface
-- x axis x topic_id. Distinct callers who pulled data on each topic, with ONE
-- Campaign staff and AI tools' shared servers counted apart. Complete weeks
-- only.
SELECT
  c.iso_week,
  c.surface,
  c.axis,
  c.topic_id,
  c.topic_name,
  c.callers,
  c.staff_callers,
  c.shared_servers,
  c.datasets_pulled,
  c.total_callers,
  c.observed
FROM `${topic_callers_weekly}` AS c
WHERE c.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
