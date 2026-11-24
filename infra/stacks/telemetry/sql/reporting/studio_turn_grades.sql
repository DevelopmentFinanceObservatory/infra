-- The view dfo_reporting.studio_turn_grades, a Terraform template
-- (reporting_views.tf): one row per Studio turn the topics Job labelled, with
-- the grader's grade and the question's topics, from ${studio_turn_topics}.
-- It holds no trace id, caller or text. final_grade, in_population and
-- audience are null until the grader grades the turn. A Studio question
-- measure counts the rows with in_population true.
SELECT
  DATE(turn_started_at) AS day,
  turn_started_at AS started_at,
  final_grade,
  in_population,
  audience,
  main_subject,
  question_topics,
  finance_kind,
  asks_for_data
FROM `${studio_turn_topics}`
