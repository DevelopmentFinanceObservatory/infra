-- The view dfo_reporting.metrics_topic_demand_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: iso_week x axis x
-- topic_id. Studio questions split across subjects by weight; unmet is the
-- grader's judgement, split into turns graded N (no_data_turns) and F
-- (missing_feature_turns). staff_share is the share of turns from ONE Campaign
-- staff accounts, a floor where turns name no consumer (unknown_caller_share). The mart suppresses topic-weeks under 5 weighted turns.
-- Weeks follow the studio surface's observation mark.
SELECT
  d.iso_week,
  d.axis,
  d.topic_id,
  COALESCE(t.name, d.topic_id) AS topic_name,
  d.suppressed,
  d.turns,
  d.unmet_turns,
  d.unmet_rate,
  d.no_data_turns,
  d.missing_feature_turns,
  d.staff_share,
  d.unknown_caller_share
FROM `${topic_demand_weekly}` AS d
JOIN `${int_surface_weeks_observed}` AS o
  ON o.surface = 'studio' AND o.iso_week = d.iso_week
LEFT JOIN `${topic_taxonomy}` AS t
  ON t.axis = d.axis AND t.topic_id = d.topic_id
WHERE o.observed AND d.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
