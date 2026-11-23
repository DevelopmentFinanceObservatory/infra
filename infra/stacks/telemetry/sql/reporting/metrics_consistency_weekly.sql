-- The view dfo_reporting.metrics_consistency_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: iso_week. Derived
-- frames recomputed in a week, and how many of those seen the week before
-- recompute to the same digest.
SELECT
  c.iso_week,
  c.frames_recomputed,
  c.frames_seen_before,
  c.frames_consistent,
  c.consistent_share,
  c.content_version_moved,
  c.engine_changed
FROM `${consistency_weekly}` AS c
WHERE c.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
