variable "project_id" {
  description = "GCP project that holds the telemetry stack's edge_logs bucket."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone id of the domain whose requests the job logs. Given directly so the token needs no Zone Read lookup."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id must be a 32-character hex string."
  }
}

variable "edge_logpush_bucket" {
  description = "GCS bucket the Logpush job in cloudflare_logpush.tf writes dataset-read request lines to, copied from the telemetry stack's edge_logs_bucket output. Null creates no job, no custom log fields and no ownership challenge."
  type        = string
  default     = null

  validation {
    condition     = var.edge_logpush_bucket == null || can(regex("^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$", var.edge_logpush_bucket))
    error_message = "edge_logpush_bucket must be a GCS bucket name, without the gs:// scheme."
  }
}
