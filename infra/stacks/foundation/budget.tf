# Gemini spend alerts, one budget per key project. A billing budget notifies.
# It caps no spend and stops no request. Every resource here is created
# only once billing_account_id and gemini_key_projects are set
# (budget.auto.tfvars).
locals {
  gemini_budget_enabled = var.billing_account_id != "" && length(var.gemini_key_projects) > 0
  gemini_budgets        = local.gemini_budget_enabled ? var.gemini_key_projects : {}

  # Billing catalog id of the "Gemini API" service, which Google's billing
  # catalog lists for generativelanguage.googleapis.com. Found with
  # GET https://cloudbilling.googleapis.com/v1/services.
  gemini_billing_service = "services/AEFD-7695-64FA"
}

# A budget calls the Cloud Billing Budget API against the billing project set
# on the provider, and its notification channels use Cloud Monitoring.
resource "google_project_service" "budget_apis" {
  for_each = local.gemini_budget_enabled ? toset([
    "billingbudgets.googleapis.com",
    "monitoring.googleapis.com",
  ]) : toset([])

  service            = each.key
  disable_on_destroy = false
}

# An email channel carries one address, so each recipient in the principals
# secret's budget_alerts object (main.tf) gets a channel, keyed and named by
# its label.
resource "google_monitoring_notification_channel" "budget_email" {
  for_each = local.gemini_budget_enabled ? toset(nonsensitive(keys(local.principals.budget_alerts))) : toset([])

  display_name = "Gemini budget alerts: ${each.key}"
  type         = "email"
  labels = {
    email_address = local.principals.budget_alerts[each.key]
  }

  depends_on = [google_project_service.budget_apis]
}

resource "google_billing_budget" "gemini" {
  for_each = local.gemini_budgets

  billing_account = var.billing_account_id
  display_name    = "Gemini API spend: ${each.key}"

  budget_filter {
    # The filter takes the project number, so the stack reads no other project.
    projects = ["projects/${each.value.project_number}"]
    services = [local.gemini_billing_service]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(each.value.budget_usd)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  # Billing account admins keep their default emails; the channels add the
  # named recipients.
  all_updates_rule {
    monitoring_notification_channels = [for c in google_monitoring_notification_channel.budget_email : c.id]
    disable_default_iam_recipients   = false
  }

  depends_on = [google_project_service.budget_apis]
}
