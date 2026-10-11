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

variable "max_connections" {
  description = "Postgres max_connections, pinned so a tier change never moves it. The default, 200, covers the stack's worst-case budget of 165 (see main.tf) and is what dev runs. Prod sets 300 in its env.auto.tfvars, below Cloud SQL's own default of 400 at 7.5 GB. Changing it restarts the instance."
  type        = number
  default     = 200
}

variable "tier" {
  description = "Cloud SQL machine type. The default, db-custom-1-3840, is one dedicated vCPU and 3.75 GB, a dedicated-core tier carrying Google's standard SLA, and is what dev runs. Prod sets db-custom-2-7680 in its env.auto.tfvars. Both instances are zonal."
  type        = string
  default     = "db-custom-1-3840"
}

variable "allowed_consumer_projects" {
  description = "Projects authorised to create a Private Service Connect endpoint against this instance's service attachment. An endpoint alone grants nothing without a matching entry here."
  type        = list(string)
}
