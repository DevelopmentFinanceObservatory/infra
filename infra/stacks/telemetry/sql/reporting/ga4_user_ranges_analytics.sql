-- The view dfo_reporting.ga4_user_ranges once var.reporting_marts_cutover is
-- on, a Terraform template (reporting_views.tf): GA4 Data API users over the
-- fixed date ranges the ga4-user-ranges workflow fetches, as ${table} holds
-- them. The analytics repository's dbt model of the same name builds that
-- table with the rule ga4_user_ranges.sql applies while the cutover is off.
SELECT
  range_kind,
  range_start,
  range_end,
  active_users,
  total_users,
  new_users,
  fetched_at
FROM `${table}`
