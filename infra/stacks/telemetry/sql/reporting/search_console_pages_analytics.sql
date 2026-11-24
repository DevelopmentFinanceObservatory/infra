-- The view dfo_reporting.search_console_pages once var.reporting_marts_cutover
-- is on, a Terraform template (reporting_views.tf): web-search clicks,
-- impressions and position per Pacific Time day and page URL, with the history
-- before the bulk export's first day, as ${table} holds them. The analytics
-- repository's dbt model of the same name builds that table with the rule
-- search_console_pages.sql applies while the cutover is off.
SELECT
  day,
  url,
  clicks,
  impressions,
  sum_position
FROM `${table}`
