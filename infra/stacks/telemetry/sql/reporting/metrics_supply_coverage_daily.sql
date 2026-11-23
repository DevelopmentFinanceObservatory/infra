-- The view dfo_reporting.metrics_supply_coverage_daily, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: day x coverage
-- (curated, data_commons, missing, unknown). Target sources on the seeded list
-- by how the day's catalogue holds them; unknown is a day whose build logged
-- no provenance lists. Complete days only.
SELECT
  s.day,
  s.coverage,
  COUNT(DISTINCT s.source_key) AS sources
FROM `${supply_coverage_daily}` AS s
WHERE s.day < CURRENT_DATE()
GROUP BY s.day, s.coverage
