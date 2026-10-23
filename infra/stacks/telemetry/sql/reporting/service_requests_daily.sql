-- The view dfo_reporting.service_requests_daily, a Terraform template
-- (reporting_views.tf): Cloud Run requests per UTC day and service, with
-- status counts and approximate latency quantiles, as ${requests_daily} holds
-- them. Quantiles do not combine across rows.
SELECT
  day,
  service,
  requests,
  status_4xx,
  status_5xx,
  latency_p50_ms,
  latency_p95_ms,
  latency_p99_ms
FROM `${requests_daily}`
