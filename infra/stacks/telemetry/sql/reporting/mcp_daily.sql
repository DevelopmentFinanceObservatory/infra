-- The view dfo_reporting.mcp_daily, a Terraform template
-- (reporting_views.tf): the combined MCP server's tool calls, resource
-- reads, resource lists and initializes per UTC day, caller kind, client,
-- request and outcome, with an HLL++ sketch of the callers, as ${mcp_daily}
-- holds them. No caller, trace id, URI or other text.
SELECT
  day,
  caller_kind,
  client,
  request,
  outcome,
  calls,
  callers_sketch
FROM `${mcp_daily}`
