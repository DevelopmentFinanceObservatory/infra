-- The view dfo_reporting.metrics_trust_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: iso_week x
-- slot_source x share_era. Replay-probe readings from complete runs only.
-- Derived cards are compared with their stored frame; dataset cards are
-- reported as still current or moved.
SELECT
  t.iso_week,
  t.slot_source,
  t.share_era,
  t.shares,
  t.derived_cards,
  t.comparable,
  t.same,
  t.different,
  t.comparable_match_rate,
  t.comparable_coverage,
  t.dataset_cards,
  t.confirmed,
  t.still_current,
  t.moved,
  t.confirmed_still_current_rate
FROM `${trust_weekly}` AS t
WHERE t.run_status = 'complete'
  AND t.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
