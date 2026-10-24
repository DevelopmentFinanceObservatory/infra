-- The view dfo_reporting.website_requests_daily, a Terraform template
-- (reporting_views.tf): the website's request lines per UTC day, route,
-- kind (page, api, rsc, prefetch, or unparsed), bot verdict and status
-- class, with an HLL++ sketch of the callers, as ${website_requests_daily}
-- holds them. No caller, host, user agent or path beyond the route.
SELECT
  day,
  route,
  kind,
  bot,
  status_class,
  requests,
  callers_sketch
FROM `${website_requests_daily}`
