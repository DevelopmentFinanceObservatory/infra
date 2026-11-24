-- The view dfo_reporting.accounts_daily once var.reporting_marts_cutover is
-- on, a Terraform template (reporting_views.tf): website accounts created per
-- UTC day and organisation, with no address and no user id, as ${table} holds
-- them. The analytics repository's dbt model of the same name builds that
-- table with the rule accounts_daily.sql applies while the cutover is off.
SELECT
  day,
  organisation,
  accounts
FROM `${table}`
