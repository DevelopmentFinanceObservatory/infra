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

variable "cloudsql_login_role_id" {
  description = "Id of this stack's project-scoped custom role for Cloud SQL IAM login without the Data API, such as dfoDevAiCloudsqlLoginOnly. See session_store.tf."
  type        = string
}

# The values below reach this stack as plain values in each environment's
# env.auto.tfvars rather than through `terraform_remote_state`. A plain
# value copied from the owning stack's output keeps this stack's plan from
# ever depending on that stack having applied, the same rationale the `apis`
# stack records for its own copies.

variable "dfo_apis_url" {
  description = "Base URL of the apis stack's Cloud Run service, which serves both the Search and Datasets APIs behind /api/search and /api/datasets. Copied from the `apis` stack's `service_url` output. A bare host with no path suffix — data-mcp holds the two path prefixes and appends them itself."
  type        = string
}

variable "apis_service_name" {
  description = "Name of the apis stack's Cloud Run service, in this stack's project and region, on which this stack grants the ai runtime service account roles/run.invoker. Copied from the `apis` stack's `service_name` output. The apis stack applies before this one, so the service exists when this grant applies."
  type        = string
}

variable "datasets_first_party_principal_secret_id" {
  description = "Secret Manager id of the shared datasets first-party principal secret. Copied from the `apis` stack's `google_secret_manager_secret.datasets_first_party_principal.secret_id` output as a plain value rather than through a `data` source: a `data \"google_secret_manager_secret\"` lookup resolves against live state at plan time, which this stack's plan must not depend on since the `apis` stack creates the secret in this same change."
  type        = string
}

variable "live_refresh_principal_secret_id" {
  description = "Secret Manager id of the live-refresh principal secret. Copied from the `apis` stack's `google_secret_manager_secret.live_refresh_principal.secret_id`. A plain value keeps this stack's plan independent of whether the `apis` stack has created the secret yet, which a `data \"google_secret_manager_secret\"` lookup would not."
  type        = string
}

variable "presentation_public_url" {
  description = "Public URL prefix under which presentation-mcp is reachable from a browser. It is the website's /mcp/presentation route, which forwards to this service's per-server mount. The app views resolve their theme stylesheet against it. Copied from the `website` stack's `website_url` value plus the path, a plain value so this plan never depends on that stack having applied. The service fails to start without it."
  type        = string
}

variable "site_origin" {
  description = "Public origin of the website, with no path, such as https://developmentfinance.org. data-mcp builds the artifact links it hands to models from it, and the website proxies those links to the apis service. Copied from the `website` stack's `website_url` value, a plain value so this plan never depends on that stack having applied. The service fails to start without it."
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+$", var.site_origin))
    error_message = "site_origin must start with https:// and carry no path or trailing slash."
  }
}

variable "studio_token_readers" {
  description = "IAM members granted secretAccessor on the studio API token secret alone, the humans who call the studio routes from their own machines."
  type        = list(string)
}

variable "mcp_token_readers" {
  description = "IAM members granted secretAccessor on the MCP API token secret alone, the callers who reach the raw MCP tool mounts from outside the service. Empty by default: the token reaches the tools directly, below the studio routes, so each member is added as one needs that access."
  type        = list(string)
  default     = []
}

variable "platform_postgres_instance_name" {
  description = "Name of the shared Cloud SQL instance from the `platform` stack. Copied from that stack's `instance_name` output."
  type        = string
}

variable "platform_postgres_connection_name" {
  description = "Connection name (project:region:instance) of the shared Cloud SQL instance from the `platform` stack, the value the Cloud SQL connector resolves an instance from. Copied from that stack's `connection_name` output."
  type        = string
}

variable "stateless_deletion_protection" {
  description = "Deletion protection for this stack's Cloud Run services and Jobs, the same flag the dcp stack passes to its Cloud Run resources. They hold no data of their own, so this guards against an accidental destroy or replace rather than data loss. Off in dfo-dev, so `terraform destroy` and replaces stay unblocked; on in dfo-prod."
  type        = bool
}
