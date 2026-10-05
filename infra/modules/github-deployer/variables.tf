variable "project_id" {
  description = "GCP project the deployer service account lives in."
  type        = string
}

variable "project_number" {
  description = "GCP project number. Used to build the WIF principalSet member; get it from data.google_project, never hardcode it."
  type        = string
}

variable "pool_id" {
  description = "Short workload_identity_pool_id of the (shared, root-owned) WIF pool, e.g. \"github-pool\"."
  type        = string
}

variable "repository" {
  description = "GitHub repository this service account's WIF binding is scoped to, as \"owner/repo\"."
  type        = string
}

variable "repository_id" {
  description = "Numeric GitHub repository id of var.repository, as a string. Immutable across renames and transfers, unlike the name, so the ref- and environment-scoped bindings compose from it. Not the Artifact Registry repository_id in var.artifact_registry_repositories."
  type        = string
}

variable "account_id" {
  description = "Service account id (<=30 chars), e.g. \"dfo-infra-planner\"."
  type        = string
}

variable "display_name" {
  description = "Service account display name. Defaults to account_id when unset."
  type        = string
  default     = ""
}

variable "description" {
  description = "Service account description."
  type        = string
  default     = ""
}

variable "project_roles" {
  description = "Project-level IAM roles to grant the service account, one google_project_iam_member per entry."
  type        = list(string)
  default     = []
}

variable "state_bucket" {
  description = "Terraform state GCS bucket to grant state_bucket_role on. Leave null (with state_bucket_role) if the service account's project_roles already cover the state bucket."
  type        = string
  default     = null
}

variable "state_bucket_role" {
  description = "IAM role to grant on state_bucket, e.g. \"roles/storage.objectViewer\". Required when state_bucket is set."
  type        = string
  default     = null
}

variable "state_bucket_object_prefixes" {
  description = "Object-name prefixes within state_bucket (e.g. \"terraform/state/dfo-dev/foundation/\") that state_bucket_role's object-scoped permissions are restricted to. Leave null (the default) for an unconditioned grant across the whole bucket. Bucket-scoped permissions in state_bucket_role, notably storage.objects.list, are authorized against the Bucket resource rather than any Object, so a condition built only from these prefixes would deny the backend's own listing calls; the module unions them with an unconditioned allow on the Bucket resource itself, which still lets the grantee enumerate object names bucket-wide without granting it their contents."
  type        = list(string)
  default     = null
}

variable "wif_ref" {
  description = "If set, restrict WIF impersonation to GitHub Actions jobs running on this git ref, via a principalSet:// binding on attribute.repo_ref, or on attribute.repo_env_ref when wif_environment is also set — instead of any workflow in the repo (the default repo-scoped principalSet). Use for privileged SAs whose CI only runs on a protected branch. Example: refs/heads/main. Combine with wif_environment to require both."
  type        = string
  default     = null
}

variable "wif_environment" {
  description = "If set, restrict WIF impersonation to GitHub Actions jobs running under this GitHub Environment, via a principalSet:// binding on attribute.repo_environment — instead of any workflow in the repo (the default repo-scoped principalSet). A job declaring an Environment also carries a ref claim, so wif_ref would admit it too; this is the boundary that actually says the Environment is the gate. Example: dev. Combine with wif_ref to pin the deploying branch as well, which an image deployer should: on its own this mode delegates the choice of refs to that Environment's deployment branch policy, which lives in the service repository."
  type        = string
  default     = null
}

variable "artifact_registry_repositories" {
  description = "Artifact Registry repositories to grant repository-scoped roles on, one google_artifact_registry_repository_iam_member per entry, instead of granting those roles project-wide. Roles with no resource-scoped IAM equivalent still belong in project_roles."
  type = list(object({
    repository_id = string
    location      = string
    role          = string
  }))
  default = []
}
