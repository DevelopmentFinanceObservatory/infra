-- The view dfo_reporting.search_console_daily while
-- var.analytics_dbt_schedule_enabled is on, a Terraform template
-- (reporting_views.tf): web-search clicks, impressions and position for the
-- property per Pacific Time day, the API history before the bulk export's
-- first day and the export from then on, as ${table} holds them. The analytics
-- repository's dbt model of the same name builds that table with the rule
-- search_console_daily.sql applies when the switch is off.
SELECT
  day,
  clicks,
  impressions,
  sum_position
FROM `${table}`
