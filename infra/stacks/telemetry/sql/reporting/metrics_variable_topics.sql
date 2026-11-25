-- The view dfo_reporting.metrics_variable_topics, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: axis x topic_id.
-- Today's catalogue variables by main subject and by finance kind, from
-- int_variable_topics (labels that are not stale). Totals dip while a topics
-- run re-asks changed variables.
WITH labelled AS (
  SELECT 'subject' AS axis, main_subject AS topic_id, variable_dcid
  FROM `${int_variable_topics}`
  WHERE NOT stale
  UNION ALL
  SELECT 'finance_kind' AS axis, finance_kind AS topic_id, variable_dcid
  FROM `${int_variable_topics}`
  WHERE NOT stale
)
SELECT
  l.axis,
  l.topic_id,
  ANY_VALUE(COALESCE(t.name, l.topic_id)) AS topic_name,
  COUNT(DISTINCT l.variable_dcid) AS variables
FROM labelled AS l
LEFT JOIN `${topic_taxonomy}` AS t
  ON t.axis = l.axis AND t.topic_id = l.topic_id
GROUP BY l.axis, l.topic_id
