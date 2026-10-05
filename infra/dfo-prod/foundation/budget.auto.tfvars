# Inputs for the Gemini spend budget (budget.tf). Both empty values below keep
# the budget switched off; see infra/dfo-dev/foundation/README.md "Gemini
# spend budget" for how to fill them in. The monthly amount is
# gemini_budget_usd, which defaults to 500 USD in variables.tf; set it here to
# give prod its own figure.
billing_account_id        = ""
gemini_key_project_number = ""
budget_alert_emails       = []
