variable "project_id" {
  description = "GCP project this environment deploys into."
  type        = string
}

variable "region" {
  description = "Default GCP region for regional resources."
  type        = string
}

variable "namespace" {
  description = "Prefix for this environment's resource names, such as dfo-dev."
  type        = string
}

variable "tier" {
  description = "Cloud SQL machine type. db-custom-1-3840 is one dedicated vCPU and 3.75 GB, a dedicated-core tier carrying Google's standard SLA. Production is the same shape stepped up, with availability_type = REGIONAL and a larger tier, neither of which this stack sets."
  type        = string
  default     = "db-custom-1-3840"
}

variable "allowed_consumer_projects" {
  description = "Projects authorised to create a Private Service Connect endpoint against this instance's service attachment. An endpoint alone grants nothing without a matching entry here."
  type        = list(string)
}
