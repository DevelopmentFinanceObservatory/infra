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

variable "reporting_readers" {
  description = "Principals that read the dfo_reporting dataset, as IAM member strings such as group:dfo-dashboard-readers@one.org. Each gets READER on the dataset and roles/bigquery.jobUser and roles/mcp.toolUser on the project, and no access to the datasets the reporting views read."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for m in var.reporting_readers : can(regex("^(group|user|serviceAccount|domain):[^:]+$", m))])
    error_message = "Each reporting_readers entry must be group:, user:, serviceAccount: or domain: followed by an address."
  }
}

variable "search_console_export_account" {
  description = "Service account Search Console's bulk data export writes as."
  type        = string
  default     = "search-console-data-export@system.gserviceaccount.com"
}

variable "alert_emails" {
  description = "Addresses notified when the logs_daily scheduled query or an export Job fails, each through its own Cloud Monitoring email channel."
  type        = list(string)

  validation {
    condition     = length(var.alert_emails) > 0 && alltrue([for e in var.alert_emails : can(regex("^[^@\\s]+@[^@\\s]+$", e))])
    error_message = "alert_emails must hold at least one email address."
  }
}
