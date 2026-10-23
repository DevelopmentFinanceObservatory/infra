# Inputs for the Gemini spend budgets (budget.tf), one budget per key project.
# The empty values below keep the budgets switched off; see
# infra/dfo-prod/foundation/README.md "Gemini spend budgets" for the values to
# fill in. Each entry's budget_usd defaults to 500 USD a month in
# variables.tf.
billing_account_id  = ""
gemini_key_projects = {}
