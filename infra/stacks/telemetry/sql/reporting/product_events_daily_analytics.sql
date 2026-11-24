-- The view dfo_reporting.product_events_daily while
-- var.analytics_dbt_schedule_enabled is on, a Terraform template
-- (reporting_views.tf): website product events per UTC day, event name, page
-- with ids written :id, and signed-in state, with HLL++ sketches of visitors
-- and users, as ${table} holds them. The analytics repository's dbt model of
-- the same name builds that table with the rule product_events_daily.sql
-- applies when the switch is off.
SELECT
  day,
  event,
  page,
  signed_in,
  events,
  visitors_sketch,
  users_sketch
FROM `${table}`
