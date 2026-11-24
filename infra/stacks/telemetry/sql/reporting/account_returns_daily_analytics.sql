-- The view dfo_reporting.account_returns_daily once
-- var.reporting_marts_cutover is on, a Terraform template
-- (reporting_views.tf): HLL++ sketches of the signed-in website accounts
-- active per UTC day and of those returning after their first active day, as
-- ${table} holds them. The analytics repository's dbt model of the same name
-- builds that table with the rule account_returns_daily.sql applies while the
-- cutover is off.
SELECT
  day,
  active_sketch,
  returning_sketch
FROM `${table}`
