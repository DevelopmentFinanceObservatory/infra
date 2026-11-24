-- The view dfo_reporting.ga4_pages_daily once var.reporting_marts_cutover is
-- on, a Terraform template (reporting_views.tf): GA4 page views and sessions
-- per day in the property's reporting time zone and page path, with the
-- history before the export's first day, as ${table} holds them. The analytics
-- repository's dbt model of the same name builds that table with the rule
-- ga4_pages_daily.sql applies while the cutover is off.
SELECT
  day,
  page_path,
  page_views,
  sessions,
  declined_page_views
FROM `${table}`
