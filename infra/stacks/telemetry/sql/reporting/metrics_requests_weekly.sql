-- The view dfo_reporting.metrics_requests_weekly, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: iso_week x
-- service. Requests and server errors per Cloud Run service, summed from days
-- to complete weeks. availability is the share of requests without a 5xx
-- response; 4xx responses count as answered.
SELECT
  r.service,
  DATE_TRUNC(r.day, ISOWEEK) AS iso_week,
  COUNT(DISTINCT r.day) AS days,
  SUM(r.requests) AS requests,
  SUM(r.status_4xx) AS status_4xx,
  SUM(r.status_5xx) AS status_5xx,
  SAFE_DIVIDE(SUM(r.requests) - SUM(r.status_5xx), SUM(r.requests)) AS availability
FROM `${requests_daily}` AS r
WHERE r.day < DATE_TRUNC(CURRENT_DATE(), ISOWEEK)
GROUP BY r.service, iso_week
