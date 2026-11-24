-- The view dfo_reporting.studio_turn_grades_daily, a Terraform template
-- (reporting_views.tf): Studio turns the topics Job labelled per UTC day of
-- the turn's start, grade, population flag, audience, main subject, finance
-- kind and whether the question asks for data, from ${studio_turn_topics}.
-- It holds counts only: no turn, time, trace id, caller or text. final_grade,
-- in_population and audience are null until the grader grades a turn, so the
-- ungraded turns of a day share a row. A Studio question measure counts the
-- turns in the rows with in_population true.
SELECT
  DATE(turn_started_at) AS day,
  final_grade,
  in_population,
  audience,
  main_subject,
  finance_kind,
  asks_for_data,
  COUNT(*) AS turns
FROM `${studio_turn_topics}`
GROUP BY day, final_grade, in_population, audience, main_subject, finance_kind, asks_for_data
