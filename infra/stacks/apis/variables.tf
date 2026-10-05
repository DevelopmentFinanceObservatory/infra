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
  description = "Id of this stack's project-scoped custom role for Cloud SQL IAM login without the Data API, such as dfoDevApisCloudsqlLoginOnly. See datasets_access.tf."
  type        = string
}

# A bare host. The search client appends `/core/api/v2` itself, so a value
# carrying the API root fails every call. The two Datasets URLs below take the
# opposite shape.
variable "search_graph_base" {
  description = "Base URL of the Data Commons graph the search engine resolves natural-language requests against."
  type        = string
}

# A dated release. The `gemini-flash-lite-latest` alias floats, so Google can
# change the model behind a running revision with no image or revision to
# record it, and frozen evaluation baselines stop being reproducible.
variable "search_engine_model" {
  description = "Gemini model the search engine uses to resolve natural-language requests."
  type        = string
  default     = "gemini-3.5-flash-lite"
}

# Comma-separated browser-origin allowlist for CORS, applied platform-wide
# across every surface this service mounts. Empty means no CORS headers
# are added at all — a wildcard is never used. This stays empty until the
# in-container Search API is retired and the Data Commons service's
# browser-side prototypes start calling this service cross-origin.
variable "dfo_cors_origins" {
  description = "Comma-separated allowlist of browser origins permitted to call the API cross-origin, applied platform-wide across every mounted surface. Empty disables CORS headers entirely; never set to a wildcard."
  type        = string
  default     = ""
}

# Two variables for one value. The graph and SDMX endpoints are separate
# fields on the app's settings, so each can point at its own deployment.
variable "datasets_graph_base_url" {
  description = "Data Commons API root the Datasets API's graph client calls, down to and including `/core/api`. The client appends `/v2/node` straight onto it, so a bare host answers 405."
  type        = string
}

variable "datasets_sdmx_base_url" {
  description = "Data Commons API root the Datasets API's SDMX client calls, down to and including `/core/api`. The client appends `/sdmx/v3/...` straight onto it."
  type        = string
}

variable "dfo_datasets_surface" {
  description = "Mounts the Datasets API surface when truthy. `dfo_apis.app._datasets_surface_enabled` reads this as `DFO_DATASETS_SURFACE`, strips and lowercases it, and treats \"1\" or \"true\" as truthy. Anything else, including unset, leaves the surface unmounted. \"true\" is the documented idiom."
  type        = string
  default     = "true"
}

# The Graph API's DCP client, not the Datasets API's, but the same shape and
# the same dev graph, kept as its own variable per the house convention that
# each consumer gets its own variable even where the value coincides.
variable "graph_dcp_base_url" {
  description = "Data Commons API root the Graph API's DCP client calls, down to and including `/core/api`. `materialise.graph.LiveGraphReader` appends `/v2/node` and `/v2/observation` straight onto it, so a bare host fails every call."
  type        = string
}

variable "dfo_graph_surface" {
  description = "Mounts the Graph API surface when truthy. `dfo_apis.app._graph_surface_enabled` reads this as `DFO_GRAPH_SURFACE`, strips and lowercases it, and treats \"1\" or \"true\" as truthy. Anything else, including unset, leaves the surface unmounted. \"true\" is the documented idiom."
  type        = string
  default     = "true"
}

variable "dfo_skills_surface" {
  description = "Mounts the Skills API surface at `/api/skills` when truthy. `dfo_apis.app._SurfaceFlags` reads this as `DFO_SKILLS_SURFACE`, strips and lowercases it, and treats \"1\" or \"true\" as truthy. Anything else, including unset, leaves the surface unmounted. \"true\" is the documented idiom. The surface shares the Search surface's graph client and skills index, so it needs no variable beyond this flag."
  type        = string
  default     = "true"
}

# The values below reach this stack as plain values in each environment's
# env.auto.tfvars rather than through `terraform_remote_state`. A plain
# value copied from the owning stack's output keeps this stack's plan from
# ever depending on that stack having applied, the same rationale the `dcp`
# stack records for its own copies. `network.tf` and
# `datasets_migrate_job.tf` each declare more of the same shape, next to the
# resources that consume them.

# The website proxies `/api/*` to this service, so its origin is the one
# every download bundle link is built on.
variable "dfo_public_site_url" {
  description = "Origin of the public website, read by dfo-apis as `DFO_PUBLIC_SITE_URL`. Download bundles build every link on it, and the service and datasets worker refuse to start without it. A bare origin with no path or trailing slash."
  type        = string
}

variable "datacommons_service_name" {
  description = "Cloud Run service name of this environment's Data Commons service, as the IAM member resource and the Cloud Run Admin API resource name take it. Copied from the `dcp` stack's `datacommons_service_name` output. graph_generation_access.tf's grant and main.tf's `DFO_GRAPH_GENERATION_SERVICE` both read it."
  type        = string
}

variable "datasets_working_bucket_name" {
  description = "Name of the GCS bucket the Datasets API writes to while a dataset build is in progress. Copied from the `dcp` stack's `datasets_working_bucket_name` output."
  type        = string
}

variable "datasets_pinned_bucket_name" {
  description = "Name of the GCS bucket that holds published dataset artifacts referenced by digest. Copied from the `dcp` stack's `datasets_pinned_bucket_name` output."
  type        = string
}

variable "platform_postgres_instance_name" {
  description = "Name of the shared Cloud SQL instance from the `platform` stack. Copied from that stack's `instance_name` output."
  type        = string
}

variable "platform_postgres_connection_name" {
  description = "Connection name (project:region:instance) of the shared Cloud SQL instance from the `platform` stack, the value the Cloud SQL connector resolves an instance from. Copied from that stack's `connection_name` output."
  type        = string
}

variable "datasets_database_name" {
  description = "Name of the Datasets API's database on the shared Cloud SQL instance. Copied from the `dcp` stack's `datasets_database_name` output."
  type        = string
}

variable "presentation_database_name" {
  description = "Name of the Presentation API's database on the shared Cloud SQL instance. Copied from the `dcp` stack's `presentation_database_name` output."
  type        = string
}

variable "datasets_migrator_secret_id" {
  description = "Fully-qualified Secret Manager id (projects/.../secrets/...) of the secret holding the Datasets API migrator user's built-in password. Copied from the `dcp` stack's `datasets_migrator_secret_id` output."
  type        = string
}

variable "presentation_migrator_secret_id" {
  description = "Fully-qualified Secret Manager id (projects/.../secrets/...) of the secret holding the Presentation API migrator user's built-in password. Copied from the `dcp` stack's `presentation_migrator_secret_id` output."
  type        = string
}

variable "dfo_presentation_surface" {
  description = "Mounts the Presentation API surface when truthy. `dfo_apis.app._presentation_surface_enabled` reads this as `DFO_PRESENTATION_SURFACE`, strips and lowercases it, and treats \"1\" or \"true\" as truthy. Anything else, including unset, leaves the surface unmounted. \"true\" is the documented idiom. The surface's lifespan opens a pool against the presentation database and expects its schema present, which the presentation_migrate Job applies."
  type        = string
  default     = "true"
}

variable "datasets_first_party_principal_readers" {
  description = "IAM members granted secretAccessor on the datasets first-party principal secret alone, humans who need to read the value directly rather than through a running service. Empty by default: the `apis` and `ai` services carry the value between themselves through their own secret_env_vars grants, so no human needs read access until one does."
  type        = list(string)
  default     = []
}

variable "datasets_pin_principal_readers" {
  description = "IAM members granted secretAccessor on the datasets pin principal secret alone, humans who need to read the value directly rather than through a running service. Empty by default: the `apis` service mounts it directly and the `website` stack's service carries it through its own secret_env_vars grant, so no human needs read access until one does."
  type        = list(string)
  default     = []
}

# The UN System Data Commons is a stock Custom Data Commons federated with
# base Data Commons. The job reads its provenances and agency root groups
# over the public internet. It serves GET and POST to /v2/node anonymously.
# A build records UN rows and the places the UN front door refuses from the
# deployment it read, so the job, the apis service (main.tf) and the
# datasets worker (datasets_worker.tf) all set UN_GRAPH_BASE_URL from this
# one variable, the only name dfo-apis reads for it.
variable "un_graph_base_url" {
  description = "API root of the UN System Data Commons, down to and including `/core/api`, set as UN_GRAPH_BASE_URL on the origin catalogue job, the apis service and the datasets worker. The clients append `/v2/node` straight onto it."
  type        = string
  default     = "https://unsd-datacommons.gcp.un-icc.cloud/core/api"
}

variable "stateless_deletion_protection" {
  description = "Deletion protection for this stack's Cloud Run services and Jobs, the same flag the dcp stack passes to its Cloud Run resources. They hold no data of their own, so this guards against an accidental destroy or replace rather than data loss. Off in dfo-dev, so `terraform destroy` and replaces stay unblocked; on in dfo-prod."
  type        = bool
}
