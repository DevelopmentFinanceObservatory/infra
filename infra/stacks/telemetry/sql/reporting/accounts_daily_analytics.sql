-- The view dfo_reporting.accounts_daily while
-- var.analytics_dbt_schedule_enabled is on, a Terraform template
-- (reporting_views.tf): website accounts created per UTC day and organisation,
-- with no address and no user id, as ${table} holds them. The analytics
-- repository's dbt model of the same name builds that table with the rule
-- accounts_daily.sql applies when the switch is off.
SELECT
  day,
  organisation,
  accounts
FROM `${table}`
