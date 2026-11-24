-- The view dfo_reporting.declared_agent_requests_daily, a Terraform template
-- (reporting_views.tf): website requests per UTC day, route, kind, declared
-- agent and status class from crawlers, assistants and other agents that name
-- themselves in their User-Agent, as ${declared_agent_requests_daily} holds
-- them, through yesterday. retrievals counts the GETs answered 2xx.
SELECT
  day,
  route,
  kind,
  declared_agent,
  declared_agent_name,
  status_class,
  requests,
  retrievals
FROM `${declared_agent_requests_daily}`
