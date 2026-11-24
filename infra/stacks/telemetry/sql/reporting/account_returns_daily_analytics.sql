-- The view dfo_reporting.account_returns_daily while
-- var.analytics_dbt_schedule_enabled is on, a Terraform template
-- (reporting_views.tf): HLL++ sketches of the signed-in website accounts
-- active per UTC day and of those returning after their first active day, as
-- ${table} holds them. The analytics repository's dbt model of the same name
-- builds that table with the rule account_returns_daily.sql applies when the
-- switch is off.
SELECT
  day,
  active_sketch,
  returning_sketch
FROM `${table}`
