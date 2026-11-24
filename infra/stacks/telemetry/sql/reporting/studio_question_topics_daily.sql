-- The view dfo_reporting.studio_question_topics_daily, a Terraform template
-- (reporting_views.tf): the topics of Studio questions per UTC day of the
-- turn's start, population flag and audience, from ${studio_turn_topics}.
-- turns counts the turns whose question names the topic, and weight sums the
-- topic's weight in each, so a day's weights sum to its turns. It holds counts
-- only: no turn, time, trace id, caller or text. in_population and audience
-- are null until the grader grades a turn.
SELECT
  DATE(turn.turn_started_at) AS day,
  turn.in_population,
  turn.audience,
  topic.topic_id,
  COUNT(*) AS turns,
  SUM(topic.weight) AS weight
FROM `${studio_turn_topics}` AS turn
CROSS JOIN UNNEST(turn.question_topics) AS topic
GROUP BY day, turn.in_population, turn.audience, topic.topic_id
