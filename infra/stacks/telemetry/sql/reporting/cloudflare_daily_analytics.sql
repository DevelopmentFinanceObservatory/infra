-- The view dfo_reporting.cloudflare_daily while
-- var.analytics_dbt_schedule_enabled is on, a Terraform template
-- (reporting_views.tf): Cloudflare page loads per UTC day from the Cloudflare
-- history capture, as ${table} holds them. The analytics repository's dbt
-- model of the same name builds that table with the rule cloudflare_daily.sql
-- applies when the switch is off.
SELECT
  day,
  page_loads,
  verified_bot_page_loads
FROM `${table}`
