ga4_export_dataset     = "analytics_556773461"
billing_export_dataset = "billing_export"

# The projects model_spend_daily keeps, by project id, with the caller each
# one's spend belongs to. gen-lang-client-0530528735 holds the AI Studio key
# every prod Gemini caller shares until each has its own key project.
spend_callers = {
  "prod-fin-observatory"       = "platform"
  "gen-lang-client-0530528735" = "gemini-shared-key"
}
