variable "project_id" {
  description = "GCP project this environment deploys into."
  type        = string
}

variable "region" {
  description = "Region of the website's Cloud Run service, where the serverless network endpoint group lives."
  type        = string
}

variable "namespace" {
  description = "Prefix for this environment's resource names, such as dfo-prod."
  type        = string
}

variable "domain" {
  description = "Apex domain the load balancer serves. The managed certificate covers it and its wildcard."
  type        = string
}

variable "website_service_name" {
  description = "Name of the website's Cloud Run service in var.region, which the load balancer routes every request to."
  type        = string
}

variable "lb_log_sample_rate" {
  description = "Fraction of requests the backend service logs to Cloud Logging, from 0 to 1."
  type        = number
  default     = 1

  validation {
    condition     = var.lb_log_sample_rate >= 0 && var.lb_log_sample_rate <= 1
    error_message = "lb_log_sample_rate must be between 0 and 1."
  }
}

variable "origin_auth_header_name" {
  description = "Request header Cloudflare adds and Cloud Armor checks to admit a request. Lower case, because Cloud Armor matches header names in lower case."
  type        = string
  default     = "x-dfo-edge-auth"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.origin_auth_header_name))
    error_message = "origin_auth_header_name must be lower-case letters, digits, and hyphens."
  }
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone id of var.domain. Given directly so the token needs no Zone Read lookup."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id must be a 32-character hex string."
  }
}

variable "serve_from_lb" {
  description = "Point the apex and www records at the load balancer. False keeps them on the holding page."
  type        = bool
  default     = false
}

variable "edge_rate_limit_requests_per_10s" {
  description = "Requests one IP may send to the API routes in 10 s before Cloudflare blocks it for 10 s."
  type        = number

  validation {
    condition     = var.edge_rate_limit_requests_per_10s >= 1 && floor(var.edge_rate_limit_requests_per_10s) == var.edge_rate_limit_requests_per_10s
    error_message = "edge_rate_limit_requests_per_10s must be a whole number of at least 1."
  }
}

variable "preview_access_email_domains" {
  description = "Email domains Cloudflare Access admits to the preview host, such as one.org."
  type        = list(string)
}

variable "preview_access_emails" {
  description = "Individual email addresses Cloudflare Access admits to the preview host, beyond preview_access_email_domains."
  type        = list(string)
  default     = []
}
