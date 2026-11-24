variable "project_id" {
  description = "GCP project this environment deploys into."
  type        = string
}

variable "region" {
  description = "Default GCP region for regional resources."
  type        = string
}
