# The reporting views' sources (infra/stacks/telemetry/reporting_views.tf).
# Add a group to reporting_sources once the table the README's "Reporting
# views" names for it exists. The next apply creates the group's views and
# their authorised-view entries.
reporting_sources = ["logs", "mcp", "website_requests", "website", "accounts", "langfuse", "billing", "ga4", "search_console"]

ga4_export_dataset     = "analytics_556773461"
billing_export_dataset = "billing_export"

# The projects model_spend_daily keeps, by project id, with the caller each
# one's spend belongs to. gen-lang-client-0530528735 holds the AI Studio key
# every prod Gemini caller shares until each has its own key project.
spend_callers = {
  "prod-fin-observatory"       = "platform"
  "gen-lang-client-0530528735" = "gemini-shared-key"
}
