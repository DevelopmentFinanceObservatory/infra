-- The view dfo_reporting.service_routes_daily, a Terraform template
-- (reporting_views.tf): Cloud Run requests per UTC day, service, method and
-- route, as ${routes_daily} holds them. The route is the request path with
-- its ids written :id (sql/normalise_route.sql), so it holds no id and no
-- query string. Quantiles do not combine across rows.
SELECT
  day,
  service,
  method,
  route,
  requests,
  status_4xx,
  status_5xx,
  latency_p50_ms,
  latency_p95_ms,
  latency_p99_ms
FROM `${routes_daily}`
