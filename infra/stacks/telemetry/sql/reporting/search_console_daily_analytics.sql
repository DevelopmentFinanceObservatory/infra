-- The view dfo_reporting.search_console_daily once var.reporting_marts_cutover
-- is on, a Terraform template (reporting_views.tf): web-search clicks,
-- impressions and position for the property per Pacific Time day, the API
-- history before the bulk export's first day and the export from then on, as
-- ${table} holds them. The analytics repository's dbt model of the same name
-- builds that table with the rule search_console_daily.sql applies while the
-- cutover is off.
SELECT
  day,
  clicks,
  impressions,
  sum_position
FROM `${table}`
