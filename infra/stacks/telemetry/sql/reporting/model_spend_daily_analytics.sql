-- The view dfo_reporting.model_spend_daily while
-- var.analytics_dbt_schedule_enabled is on, a Terraform template
-- (reporting_views.tf): Cloud Billing cost per UTC day, DFO caller, service,
-- SKU and currency, for the projects the analytics spend_callers seed lists,
-- through the day before yesterday, as ${table} holds them. The analytics
-- repository's dbt model of the same name builds that table with the rule
-- model_spend_daily.sql applies when the switch is off.
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
