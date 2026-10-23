# Committed, non-secret dcp config for prod. The Data Commons API key is
# secret and comes from the dc-api-key Secret Manager secret (dfo.tf,
# dfo_override.tf). variables.tf is CLI-owned and keeps upstream defaults,
# so every value below is set explicitly, and the guard in dfo.tf fails plan
# if region or namespace is left at its default. See
# infra/dfo-dev/dcp/dfo.auto.tfvars for the reasoning behind each value.

# =============================================================================
# Global Configuration
# =============================================================================
project_id = "prod-fin-observatory"
namespace  = "dfo-prod"
region     = "europe-west1"

# The Gemini key the DFO prototype app reads (dfo.tf).
# One Gemini key per caller, each from its own AI Studio project.
search_api_gemini_api_key_secret_id = "dfo-prod-dcp-gemini-api-key"

stateful_deletion_protection  = true
skip_container_restarts       = true
stateless_deletion_protection = true

# =============================================================================
# Storage Module
# =============================================================================
storage_create_artifacts_bucket = false
storage_artifacts_bucket_name   = "dfo-prod-dc-artifacts-prod-fin-observatory"

# =============================================================================
# Redis Module
# =============================================================================
enable_redis = false

# =============================================================================
# Spanner Module
# =============================================================================
spanner_create_instance  = true
spanner_processing_units = 1000

# =============================================================================
# Datacommons Services Module
# =============================================================================
# Only our own identities may call the service: the apis stack grants
# roles/run.invoker to each caller (infra/stacks/apis/dcp_access.tf), and the
# callers send a Google ID token in X-Serverless-Authorization. Browsers
# cannot, so the Data Commons web UI and /prototype are not public. The Maps
# key stays: the services image exits at start without MAPS_API_KEY.
datacommons_services_allow_unauthenticated_access = false
datacommons_services_min_instances                = 1
datacommons_services_max_instances                = 2
datacommons_services_cpu                          = "4"
datacommons_services_memory                       = "16G"

# =============================================================================
# Ingestion
# =============================================================================
ingestion_input_path                = "ingestion/input"
spanner_create_bigquery_reservation = true

# datacommons_services_image lives in image.auto.tfvars, which dfo-dcp's
# deploy workflow writes.

# =============================================================================
# Datasets API (dfo_datasets.tf)
# =============================================================================
datasets_working_bucket_name = "prod-fin-observatory-datasets-working"
datasets_pinned_bucket_name  = "prod-fin-observatory-datasets-pinned"

# Every site origin that fetches dataset files through a signed URL. No
# deployed site does yet, and dev lists only localhost, so prod lists none.
datasets_cors_origins = []

# The platform stack names its instance "${namespace}-platform-postgres".
platform_postgres_instance_name   = "dfo-prod-platform-postgres"
platform_postgres_connection_name = "prod-fin-observatory:europe-west1:dfo-prod-platform-postgres"

datasets_database_name = "datasets"

# =============================================================================
# Presentation API (dfo_presentation.tf)
# =============================================================================
presentation_database_name = "presentation"
