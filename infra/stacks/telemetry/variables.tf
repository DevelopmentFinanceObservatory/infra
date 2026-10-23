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
