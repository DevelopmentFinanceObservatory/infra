-- The view dfo_reporting.product_events_daily once var.reporting_marts_cutover
-- is on, a Terraform template (reporting_views.tf): website product events per
-- UTC day, event name, page with ids written :id, and signed-in state, with
-- HLL++ sketches of visitors and users, as ${table} holds them. The analytics
-- repository's dbt model of the same name builds that table with the rule
-- product_events_daily.sql applies while the cutover is off.
SELECT
  day,
  event,
  page,
  signed_in,
  events,
  visitors_sketch,
  users_sketch
FROM `${table}`
