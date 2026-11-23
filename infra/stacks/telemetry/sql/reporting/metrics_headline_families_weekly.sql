-- The view dfo_reporting.metrics_headline_families_weekly, a Terraform
-- template (reporting_views.tf) over the analytics dbt marts. Grain: surface x
-- iso_week x caller_class x audience x client_family. The headline counts
-- split by client family on api and mcp. A consumer or address that used two
-- families in a week is in both rows, so consumers, addresses, spec_uses,
-- specs and indicators do not add up to metrics_headline_weekly; only
-- deliveries add. consumers is null on pooled rows, whose distinct count is
-- addresses. events names the dated_events in the week.
SELECT
  h.surface,
  h.iso_week,
  h.caller_class,
  h.audience,
  h.client_family,
  h.consumers,
  h.addresses,
  h.deliveries,
  h.spec_uses,
  h.specs,
  h.indicators,
  h.events
FROM `${headline_families_weekly}` AS h
WHERE h.observed AND h.iso_week < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
