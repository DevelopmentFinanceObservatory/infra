-- The view dfo_reporting.metrics_regular_organisations_weekly, a Terraform
-- template (reporting_views.tf) over the analytics dbt marts. Grain: surface x
-- iso_week x audience x organisation_group. Groups only; the mart suppresses
-- small groups as null.
SELECT
  r.surface,
  r.iso_week,
  r.audience,
  r.organisation_group,
  r.organisations_interim AS organisations_2_of_4,
  r.organisations AS organisations_3_of_8,
  r.accounts,
  r.regular_accounts_interim AS regular_accounts_2_of_4,
  r.regular_accounts AS regular_accounts_3_of_8,
  r.label_as_of_first_snapshot
FROM `${regular_organisations_weekly}` AS r
JOIN `${int_surface_weeks_observed}` AS o
  ON o.surface = r.surface AND o.iso_week = r.iso_week
WHERE o.observed AND r.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
