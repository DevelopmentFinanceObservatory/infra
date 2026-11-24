-- The view dfo_reporting.api_consumers_daily, a Terraform template
-- (reporting_views.tf): consumers per UTC day, surface, consumer kind, caller
-- class and audience, from ${consumer_daily}, which holds one row per day,
-- surface and consumer. The consumer keys stay out: consumers counts them, and
-- consumers_sketch is an HLL++ sketch of them, so HLL_COUNT.MERGE over several
-- days or rows counts distinct consumers. A pooled consumer stands for no one
-- person, so read the caller classes apart.
--
-- indicator_uses and spec_uses sum each consumer's distinct indicators and
-- specs used that day, so an indicator two consumers used counts twice.
-- spec_fetches does the same for the specs Studio turns fetched.
SELECT
  day,
  surface,
  consumer_kind,
  caller_class,
  audience,
  COUNT(DISTINCT consumer) AS consumers,
  HLL_COUNT.INIT(consumer, 14) AS consumers_sketch,
  SUM(indicators_used) AS indicator_uses,
  SUM(specs_used) AS spec_uses,
  SUM(specs_fetched) AS spec_fetches,
  SUM(delivery_lines) AS delivery_lines,
  SUM(backfill_reads) AS backfill_reads,
  SUM(rows_served) AS rows_served
FROM `${consumer_daily}`
GROUP BY day, surface, consumer_kind, caller_class, audience
