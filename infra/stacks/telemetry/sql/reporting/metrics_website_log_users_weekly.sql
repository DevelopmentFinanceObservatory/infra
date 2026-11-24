-- The view dfo_reporting.metrics_website_log_users_weekly, a Terraform
-- template (reporting_views.tf) over the analytics dbt marts. Grain: iso_week.
-- Website users counted from the website's own request lines, whether or not
-- they accept analytics cookies: distinct address keys with a search or a
-- share, ONE Campaign staff apart once accounts_linked is true. Observed,
-- complete weeks only.
SELECT
  u.iso_week,
  u.users,
  u.searchers,
  u.sharers,
  u.staff_users,
  u.accounts_linked
FROM `${website_log_users_weekly}` AS u
WHERE u.observed AND u.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
