-- The view dfo_reporting.metrics_website_returning_weekly, a Terraform
-- template (reporting_views.tf) over the analytics dbt marts. Grain: iso_week.
-- Website people active (a search or a share) and returning, by account,
-- consented browser id and ONE Campaign staff. Complete weeks only.
SELECT
  r.iso_week,
  r.active_accounts,
  r.active_browsers,
  r.active_staff,
  r.returning_accounts_2_of_4,
  r.returning_browsers_2_of_4,
  r.returning_staff_2_of_4,
  r.returning_accounts_3_of_8,
  r.returning_browsers_3_of_8,
  r.returning_staff_3_of_8,
  r.weeks_observed_of_last_8,
  r.weeks_observed_of_last_4
FROM `${website_returning_weekly}` AS r
WHERE r.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
