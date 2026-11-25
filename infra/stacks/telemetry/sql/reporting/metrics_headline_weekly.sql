-- The view dfo_reporting.metrics_headline_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: surface x iso_week
-- x caller_class x audience. The headline counts in consumer-weeks and spec
-- uses. consumers is null on pooled rows, whose distinct count is addresses;
-- deliveries is null on studio and page. top_caller_uses is the row's largest
-- consumer's spec uses, or its pool address's on a pooled row, and
-- top_caller_share is that over spec_uses. events names the dated_events in
-- the week, such as hackathon.
SELECT
  h.surface,
  h.iso_week,
  h.caller_class,
  h.audience,
  h.consumers,
  h.addresses,
  h.deliveries,
  h.spec_uses,
  h.specs,
  h.indicators,
  h.top_caller_uses,
  h.top_caller_share,
  h.events
FROM `${headline_weekly}` AS h
WHERE h.observed AND h.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
