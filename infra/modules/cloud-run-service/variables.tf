variable "project_id" {
  description = "GCP project the Cloud Run service and its runtime service account live in."
  type        = string
}

variable "region" {
  description = "GCP region for the Cloud Run service."
  type        = string
}

variable "service_name" {
  description = "Cloud Run service name."
  type        = string
}

variable "deletion_protection" {
  description = "Whether Terraform refuses to destroy or replace the Cloud Run service. Off where `terraform destroy` must stay unblocked, on in production."
  type        = bool
}

variable "bootstrap_image" {
  description = "Placeholder image for the first apply, before the owning repo's CI has ever pushed a real image. lifecycle.ignore_changes on the container image then keeps Terraform from ever reverting whatever image CI later points the service at."
  type        = string
  default     = "gcr.io/cloudrun/hello"
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  default     = 8080
}

variable "env_vars" {
  description = "Plaintext environment variables to set on the container, keyed by env var name."
  type        = map(string)
  default     = {}
}

variable "secret_env_vars" {
  description = "Environment variables sourced from Secret Manager, keyed by env var name. Each entry's secret_id must already exist (created by this module, another stack, or out-of-band)."
  type = map(object({
    secret_id = string
    version   = optional(string, "latest")
  }))
  default = {}
}

variable "deployer_members" {
  description = "IAM members granted roles/iam.serviceAccountUser on the runtime service account and roles/run.developer on this Cloud Run service, so their image-only `gcloud run services update` can attach the runtime SA to each new revision and update the service itself. Typically the owning repo's CI image-deployer SA."
  type        = list(string)
  default     = []
}

variable "min_instances" {
  description = "Minimum Cloud Run instance count."
  type        = number
  default     = 0
}

variable "max_instances" {
  description = "Maximum Cloud Run instance count."
  type        = number
  default     = 2
}

variable "service_max_instances" {
  description = "Combined maximum instance count across every revision receiving traffic, set as the top-level Cloud Run scaling block. Null (the default) leaves max_instances above as a per-revision cap instead."
  type        = number
  default     = null
}

variable "readiness_dependencies" {
  description = "Ids of resources the revision's creation should wait on, beyond what env_vars, secret_env_vars, and vpc_access already reference, folded into a non-functional template annotation. Empty (the default) adds no ordering constraint."
  type        = list(string)
  default     = []
}

variable "cpu" {
  description = "Container CPU limit (e.g. \"1\"). Sets the vCPU allotted to each instance. Raising it increases the per-instance-second billing rate."
  type        = string
  default     = "1"
}

variable "memory" {
  description = "Container memory limit (e.g. \"512Mi\"). Sets the memory allotted to each instance. Too little risks OOM kills under load, too much raises the per-instance-second billing rate."
  type        = string
  default     = "512Mi"
}

variable "cpu_idle" {
  description = "Whether CPU is throttled to near-zero between requests. true (the default) bills CPU only while a request is being handled. false keeps CPU fully allocated at all times, which costs more but removes throttling from the request path."
  type        = bool
  default     = true
}

variable "session_affinity" {
  description = "Routes a client's repeat requests to the same instance through a session cookie. Best-effort, since an instance terminating or reaching max concurrency or CPU breaks affinity for the next request. https://cloud.google.com/run/docs/configuring/session-affinity"
  type        = bool
  default     = false
}

variable "startup_cpu_boost" {
  description = "Grants a temporary CPU boost while an instance starts. true (the default) shortens cold-start latency at the cost of extra CPU during startup. false starts every instance at its steady-state CPU limit."
  type        = bool
  default     = true
}

variable "timeout_seconds" {
  description = "Maximum time, in seconds, a request may run before Cloud Run cancels it. Raising it lets slow requests finish but holds the serving instance, and its billed resources, occupied for longer."
  type        = number
  default     = 300

  validation {
    condition     = var.timeout_seconds >= 1 && var.timeout_seconds <= 3600
    error_message = "timeout_seconds must be between 1 and 3600, Cloud Run's own bounds for request timeout."
  }
}

variable "allow_unauthenticated" {
  description = "Grant roles/run.invoker to allUsers. Provisional: there is no auth layer yet, so this defaults to true; tighten once an auth model exists."
  type        = bool
  default     = true
}

variable "ingress" {
  description = "Which sources may reach the service's URL. INGRESS_TRAFFIC_ALL (the default) accepts the internet. INGRESS_TRAFFIC_INTERNAL_ONLY accepts only VPC and internal Google Cloud traffic. INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER accepts internal traffic plus a Cloud Load Balancing external Application Load Balancer, and refuses direct requests to the run.app URL. https://cloud.google.com/run/docs/securing/ingress"
  type        = string
  default     = "INGRESS_TRAFFIC_ALL"

  validation {
    condition     = contains(["INGRESS_TRAFFIC_ALL", "INGRESS_TRAFFIC_INTERNAL_ONLY", "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"], var.ingress)
    error_message = "ingress must be INGRESS_TRAFFIC_ALL, INGRESS_TRAFFIC_INTERNAL_ONLY, or INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER."
  }
}

variable "vpc_access" {
  description = "Direct VPC egress onto a consumer's own subnet — network and subnetwork self links, typically a consumer-psc-network module's network_id and subnetwork_id outputs. Null (the default) leaves the service with no VPC configuration at all, which is what ai wants. Egress is always PRIVATE_RANGES_ONLY, not caller-configurable — see README.md for why."
  type = object({
    network    = string
    subnetwork = string
  })
  default = null
}
