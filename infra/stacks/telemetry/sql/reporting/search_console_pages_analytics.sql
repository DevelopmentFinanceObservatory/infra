-- The view dfo_reporting.search_console_pages while
-- var.analytics_dbt_schedule_enabled is on, a Terraform template
-- (reporting_views.tf): web-search clicks, impressions and position per
-- Pacific Time day and page URL, with the history before the bulk export's
-- first day, as ${table} holds them. The analytics repository's dbt model of
-- the same name builds that table with the rule search_console_pages.sql
-- applies when the switch is off.
SELECT
  day,
  url,
  clicks,
  impressions,
  sum_position
FROM `${table}`
