variable "project_id" {
  description = "GCP project this environment deploys into."
  type        = string
  default     = "dev-fin-observatory"
}

variable "region" {
  description = "Default GCP region for regional resources."
  type        = string
  default     = "northamerica-northeast1"
}
