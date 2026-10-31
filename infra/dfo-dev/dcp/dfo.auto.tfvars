# Committed, non-secret dcp config. This is everything that used to live in
# the gitignored terraform.tfvars except the Data Commons API key — that key
# is secret and is sourced separately (see dfo.tf, dfo_override.tf).
# *.auto.tfvars outranks terraform.tfvars in Terraform's variable precedence,
# so a stale local terraform.tfvars left over from a `datacommons admin init`
# regen never shadows these values.

# =============================================================================
# Global Configuration
# =============================================================================
project_id = "dev-fin-observatory"
namespace  = "dfo-dev"
region     = "northamerica-northeast1"

# The Gemini key the DFO prototype app reads (dfo.tf).
# Dev shares one Gemini key across callers.
search_api_gemini_api_key_secret_id = "dfo-dev-gemini-api-key"

# Deletion protection for stateful resources holding persistent data. In the
# upstream module this maps to the Spanner *database* deletion_protection and
# the artifacts-bucket force_destroy — it does NOT cover the Spanner instance,
# an empty/replaced bucket, the BigQuery reservation, or the secrets. The CI
# destroy guard (scripts/check-destroys.sh) covers those gaps. On now that dcp
# holds real Spanner/GCS data; flip back to false only for a deliberate teardown.
stateful_deletion_protection = true

# Skips the stack module's Cloud Run FORCE_RESTART timestamp bump, which
# otherwise shows up as churn on every plan even when nothing changed. An
# image-pin change still deploys a new revision — only the unconditional
# per-apply restart goes away.
skip_container_restarts = true

# Deletion protection for stateless resources (e.g., Cloud Run, Workflows).
# Recommended to keep false in development and non-production environments to
# allow rapid updates.
stateless_deletion_protection = false

# =============================================================================
# Storage Module
# =============================================================================
# dfo_storage.tf declares the artifacts bucket so it can carry lifecycle
# rules, which the upstream module has no input for. The module receives
# the name and passes it through to its consumers.
storage_create_artifacts_bucket = false
storage_artifacts_bucket_name   = "dfo-dev-dc-artifacts-dev-fin-observatory"

# =============================================================================
# Redis Module
# =============================================================================
# Cloud Memorystore (Redis) is used to cache API and website responses,
# significantly improving performance. You may want to set this to true in production.
# Enabling it may need roles/servicenetworking.networksAdmin on the applier in
# foundation, which the role list does not currently grant. Classic Memorystore
# provisions a private services access connection, so confirm what the stack
# module creates for Redis and restore that role before flipping this on.
enable_redis = false

# =============================================================================
# Spanner Module
# =============================================================================
# To save resources, if you want have an existing Spanner instance you would
# like to reuse, set this to false and provide the ID.
spanner_create_instance = true
# spanner_instance_id     = "existing-spanner-instance"

# Compute capacity (1000 = 1 node). Online-adjustable with no downtime.
# Dev idles at 100 to save cost. Raise it to 1000 by hand for an ingestion and
# lower it afterwards; any dcp apply, including an image pin, resets it to 100.
spanner_processing_units = 100

# =============================================================================
# Datacommons Services Module
# =============================================================================
# Only our own identities may call the service: the apis stack grants
# roles/run.invoker to each caller (infra/stacks/apis/dcp_access.tf, and
# the eval reader in infra/dfo-dev/apis/eval_reader.tf), and the callers
# send a Google ID token in X-Serverless-Authorization. Browsers cannot,
# so the Data Commons web UI and /prototype are not public. DCP still
# creates its Maps key: the services image exits at start without
# MAPS_API_KEY, and with no public page the key is never served.
datacommons_services_allow_unauthenticated_access = false

# One instance stays warm because a cold start on this service is
# user-visible. max_instances = 1 caps it at exactly one instance. The
# upstream module renders a resources block with no cpu_idle or
# startup_cpu_boost input, so the instance bills full CPU and memory
# continuously. The cpu and memory values below are the cost lever.
datacommons_services_min_instances = 1
datacommons_services_max_instances = 1
datacommons_services_cpu           = "2"
datacommons_services_memory        = "8G"

# Track traffic and user interactions with your site using Google Analytics.
# datacommons_services_google_analytics_tag_id = "your-analytics-tag-id"

# =============================================================================
# Ingestion - Preprocessing Job
# =============================================================================
# The root directory path within the Cloud Storage bucket where raw data
# files are uploaded for processing.
ingestion_input_path = "ingestion/input"

# =============================================================================
# Ingestion - Postprocessing
# =============================================================================
# Provisions a dedicated BigQuery reservation (slot commitment) for Spanner federated
# queries (used internally to boost performance). This ensures query capacity for
# postprocessing / ingestion steps.
# NOTE: Only one reservation can exist per GCP project per region. If you are deploying
# multiple environments (e.g. dev and prod) in the same project, set this to true for
# one deployment, and false for all others. See Data Commons documentation for more details.
spanner_create_bigquery_reservation = true

# datacommons_services_image lives in image.auto.tfvars, not here — that file
# is machine-written by dfo-dcp's deploy workflow and carved out of
# CODEOWNERS so its pin PRs can auto-merge. See that file's header.

# =============================================================================
# Datasets API (dfo_datasets.tf)
# =============================================================================
# GCS bucket names are globally unique across all of GCP, not just this
# project; the project-id prefix here is what gives us that uniqueness.
datasets_working_bucket_name = "dev-fin-observatory-datasets-working"
datasets_pinned_bucket_name  = "dev-fin-observatory-datasets-pinned"

# TODO: add production site origins here before a browser can read
# cross-origin responses from signed URLs against the Datasets buckets.
datasets_cors_origins = ["http://localhost:3000"]

# The shared Cloud SQL instance from the `platform` stack (#29/#41). Copied
# here as plain values from that stack's `instance_name` and
# `connection_name` outputs, not read via terraform_remote_state, so this
# stack's plan never depends on platform having applied.
platform_postgres_instance_name   = "dfo-dev-platform-postgres"
platform_postgres_connection_name = "dev-fin-observatory:northamerica-northeast1:dfo-dev-platform-postgres"

datasets_database_name = "datasets"

# =============================================================================
# Presentation API (dfo_presentation.tf)
# =============================================================================
# Same shared Cloud SQL instance as the Datasets API above
# (platform_postgres_instance_name / platform_postgres_connection_name), a
# separate database rather than a second schema inside `datasets`.
presentation_database_name = "presentation"
