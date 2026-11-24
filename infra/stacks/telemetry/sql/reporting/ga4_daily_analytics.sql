-- The view dfo_reporting.ga4_daily while var.analytics_dbt_schedule_enabled is
-- on, a Terraform template (reporting_views.tf): GA4 active users, sessions
-- and page views per day in the property's reporting time zone, the Data API
-- history before the export's first day and the export from then on, as
-- ${table} holds them. The analytics repository's dbt model of the same name
-- builds that table with the rule ga4_daily.sql applies when the switch is
-- off.
SELECT
  day,
  active_users,
  sessions,
  page_views,
  declined_page_views,
  users_sketch
FROM `${table}`
