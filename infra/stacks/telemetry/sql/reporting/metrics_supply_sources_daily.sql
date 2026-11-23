-- The view dfo_reporting.metrics_supply_sources_daily, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: day x source.
-- Names each target source on the seeded list, its owner and how the day's
-- catalogue holds it. Complete days only.
SELECT
  s.day,
  s.source_name,
  s.owner_org AS owner,
  s.coverage
FROM `${supply_coverage_daily}` AS s
WHERE s.day < CURRENT_DATE()
