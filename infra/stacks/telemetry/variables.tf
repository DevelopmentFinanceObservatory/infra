variable "project_id" {
  description = "GCP project this environment deploys into."
  type        = string
}

variable "region" {
  description = "Default region for the provider. Every resource in this stack sets its own multi-region location."
  type        = string
}

variable "namespace" {
  description = "Prefix for this environment's resource names, such as dfo-prod."
  type        = string
}

variable "log_retention_days" {
  description = "Days the telemetry log bucket keeps entries, and so how far back the linked dfo_logs dataset reaches. logs_daily keeps its aggregates for longer."
  type        = number
  default     = 30
}

variable "search_console_export_account" {
  description = "Service account Search Console's bulk data export writes as."
  type        = string
  default     = "search-console-data-export@system.gserviceaccount.com"
}

variable "reporting_sources" {
  description = "Source groups whose first table exists, out of logs, mcp, website_requests, website, accounts, langfuse, ga4, search_console, cloudflare and billing. A reporting view is created, and authorised on its sources, only when the group it reads is listed (reporting_views.tf)."
  type        = set(string)

  validation {
    condition     = length(setsubtract(var.reporting_sources, ["logs", "mcp", "website_requests", "website", "accounts", "langfuse", "ga4", "search_console", "cloudflare", "billing"])) == 0
    error_message = "reporting_sources may list only logs, mcp, website_requests, website, accounts, langfuse, ga4, search_console, cloudflare and billing."
  }
}

variable "ga4_export_dataset" {
  description = "Dataset the GA4 BigQuery link exports into, analytics_<property id>."
  type        = string

  validation {
    condition     = can(regex("^analytics_[0-9]+$", var.ga4_export_dataset))
    error_message = "ga4_export_dataset must be analytics_ followed by the GA4 property id."
  }
}

variable "billing_export_dataset" {
  description = "Dataset Cloud Billing exports into, the foundation stack's billing_export_dataset_id."
  type        = string
}

variable "spend_callers" {
  description = "Project ids model_spend_daily keeps, each mapped to the label of the caller its spend belongs to. The billing account also bills projects outside DFO, which the view leaves out."
  type        = map(string)

  validation {
    condition     = length(var.spend_callers) > 0
    error_message = "spend_callers must name at least one project."
  }

  validation {
    condition     = alltrue([for id, caller in var.spend_callers : can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", id)) && can(regex("^[a-z0-9][a-z0-9._-]*$", caller))])
    error_message = "Each spend_callers key must be a project id and each value a label of lower-case letters, digits, dots, hyphens and underscores."
  }
}
