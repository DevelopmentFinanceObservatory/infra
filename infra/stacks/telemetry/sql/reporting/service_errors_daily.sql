-- The view dfo_reporting.service_errors_daily, a Terraform template
-- (reporting_views.tf): Cloud Run service and job stdout and stderr entries
-- at WARNING or above, per UTC day, service or job, logger and severity, as
-- ${errors_daily} holds them. No message text.
SELECT
  day,
  resource_type,
  service,
  logger,
  severity,
  entries
FROM `${errors_daily}`
