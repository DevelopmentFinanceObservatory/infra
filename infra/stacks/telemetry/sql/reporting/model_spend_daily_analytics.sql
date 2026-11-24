-- The view dfo_reporting.model_spend_daily once var.reporting_marts_cutover is
-- on, a Terraform template (reporting_views.tf): Cloud Billing cost per UTC
-- day, DFO caller, service, SKU and currency, for the projects in
-- var.spend_callers, through the day before yesterday, as ${table} holds them.
-- The analytics repository's dbt model of the same name builds that table with
-- the rule model_spend_daily.sql applies while the cutover is off.
SELECT
  day,
  caller,
  service,
  sku,
  cost,
  credits,
  net_cost,
  currency
FROM `${table}`
