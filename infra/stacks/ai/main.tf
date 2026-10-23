terraform {
  # 1.11 for the write-only arguments in studio_token.tf.
  required_version = ">= 1.11"

  required_providers {
    google = {
      # 7.24.0 for google_sql_provision_script in session_store.tf.
      source  = "hashicorp/google"
      version = ">= 7.24.0"
    }
    random = {
      # 3.7.0 for the ephemeral random_password in studio_token.tf.
      source  = "hashicorp/random"
      version = ">= 3.7.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Reuse the existing, already-created Gemini API key secret (not
# terraform-managed — see infra/stacks/dcp/dfo.tf for the same secret's
# other consumer) rather than creating a dedicated one for this service.
data "google_secret_manager_secret" "gemini" {
  secret_id = "${var.namespace}-gemini-api-key"
}

# The Langfuse key pair the harness exports traces with. Like the Gemini key,
# these two secrets are created outside terraform and only referenced here.
data "google_secret_manager_secret" "langfuse_public_key" {
  secret_id = "${var.namespace}-langfuse-public-key"
}

data "google_secret_manager_secret" "langfuse_secret_key" {
  secret_id = "${var.namespace}-langfuse-secret-key"
}

locals {
  # Langfuse Cloud EU, the region the Langfuse keys above belong to.
  langfuse_base_url = "https://cloud.langfuse.com"
  # Tags deployed traces so they filter apart from a local harness's, which
  # export under Langfuse's default environment. langfuse_export.tf reads
  # this environment back.
  langfuse_tracing_environment = "${var.namespace}-ai"
}

# The dfo-ai CI image-deployer (provisioned in ../foundation) needs actAs on the
# runtime SA to push image-only revision updates; it's granted that per-SA below.
data "google_service_account" "ai_deployer" {
  account_id = "dfo-ai-deployer@${var.project_id}.iam.gserviceaccount.com"
}

module "ai_service" {
  source = "../../modules/cloud-run-service"

  project_id          = var.project_id
  region              = var.region
  deletion_protection = var.stateless_deletion_protection
  service_name        = "${var.namespace}-ai"
  bootstrap_image     = "gcr.io/cloudrun/hello"
  container_port      = 8080

  secret_env_vars = {
    GOOGLE_API_KEY = { secret_id = data.google_secret_manager_secret.gemini.secret_id }
    # Both Langfuse mounts read `latest`; see the `ai` stack README's "Langfuse tracing" section.
    LANGFUSE_PUBLIC_KEY = { secret_id = data.google_secret_manager_secret.langfuse_public_key.secret_id }
    LANGFUSE_SECRET_KEY = { secret_id = data.google_secret_manager_secret.langfuse_secret_key.secret_id }
    # No version pin, unlike the two below: this stack doesn't own the
    # version resource, so this mount always reads whatever the `apis` stack
    # most recently rotated to. A rotation there reaches this service only
    # on this stack's own next apply and rollout -- see the `ai` stack
    # README's "Datasets first-party principal" section.
    DATASETS_FIRST_PARTY_PRINCIPAL = { secret_id = var.datasets_first_party_principal_secret_id }
    # Bearer value `POST /api/studio/refresh` compares requests against, the
    # call a live Studio share makes to redraw derived cards. The `apis` stack
    # owns and pins the secret. This mount reads latest, as for the principal
    # above. See the `ai` stack README's "Live-refresh principal" section.
    LIVE_REFRESH_PRINCIPAL = { secret_id = var.live_refresh_principal_secret_id }
    STUDIO_API_TOKEN = {
      secret_id = google_secret_manager_secret.studio_api_token.secret_id
      # Pinned rather than latest so warm and new instances can never disagree during a rotation; the pin moves with the version resource, rolling the service in the same apply.
      version = google_secret_manager_secret_version.studio_api_token.version
    }
    MCP_API_TOKEN = {
      secret_id = google_secret_manager_secret.mcp_api_token.secret_id
      # Pinned rather than latest so warm and new instances can never disagree during a rotation; the pin moves with the version resource, rolling the service in the same apply.
      version = google_secret_manager_secret_version.mcp_api_token.version
    }
  }

  env_vars = {
    DFO_APIS_URL            = var.dfo_apis_url
    DEFINITION_STORE_BUCKET = google_storage_bucket.definition_store.name
    FRAME_STORE_BUCKET      = google_storage_bucket.materialisation_store.name
    # The public origin and path prefix presentation-mcp's app views load their theme stylesheet from. See var.presentation_public_url.
    PRESENTATION_PUBLIC_URL = var.presentation_public_url
    # The website origin data-mcp builds artifact links from. See var.site_origin.
    DFO_SITE_ORIGIN = var.site_origin
    # The combined MCP server's service-wide ceiling on tool calls, one bucket
    # per instance shared by every outside caller (harness.combined_mcp).
    COMBINED_MCP_REQUESTS_PER_S  = "20"
    COMBINED_MCP_BURST           = "60"
    LANGFUSE_BASE_URL            = local.langfuse_base_url
    LANGFUSE_TRACING_ENVIRONMENT = local.langfuse_tracing_environment

    # Selects the engine that answers a live studio turn: "orchestrator" is one
    # agent calling tools itself, "graph" is the workflow graph. The harness
    # uses "graph" when this is unset.
    STUDIO_ENGINE = "orchestrator"

    # ADK's session store, defined in session_store.tf. The harness resolves
    # the instance through the Cloud SQL connector from these three. The
    # connector authenticates this identity over IAM, so there is no
    # password var to mount.
    SESSION_STORE_INSTANCE_CONNECTION_NAME = var.platform_postgres_connection_name
    SESSION_STORE_DATABASE                 = google_sql_database.ai_sessions.name
    SESSION_STORE_RUNTIME_DB_USER          = google_sql_user.ai_sessions_runtime.name
  }

  deployer_members = ["serviceAccount:${data.google_service_account.ai_deployer.email}"]

  # One warm instance, so a turn never waits on a cold start.
  min_instances = 1
  max_instances = 2
  cpu           = "2"
  # One process holds the harness, ADK and the three MCP servers. A 250,000-row
  # frame adds up to about 230 MiB a tool call (growth, the largest; dfo-ai
  # scripts/bench_frames.py), so 1 GiB fits about two such calls beside the
  # idle process and 2 GiB about six.
  memory = "2Gi"

  # Multi-step agent runs hold a request open well past the module's 300s
  # default. 900s keeps them from being cut off mid-run.
  timeout_seconds = 900

  startup_cpu_boost = true
  cpu_idle          = true

  # A conversation streams one segment at a time across instances, so
  # affinity keeps a conversation's requests on the instance holding its
  # lease and they rarely meet a 409. Conversation state itself lives in the
  # Postgres session store (session_store.tf).
  session_affinity = true

  allow_unauthenticated = true # provisional -- public until an auth model exists

  vpc_access = {
    network    = module.psc_network.network_id
    subnetwork = module.psc_network.subnetwork_id
  }

  # Combined cap across old and new revisions during a rollout. See this
  # stack's README, "Instance cap" section, for the connection-budget math
  # behind 2.
  service_max_instances = 2

  # The revision must not accept traffic before the runtime identity can log
  # in, since the grants and provisioning scripts below (session_store.tf)
  # take effect on Google's own IAM-propagation schedule after Terraform
  # applies them. See the module README's "Ordering a revision on
  # out-of-module resources" section.
  readiness_dependencies = [
    google_project_iam_member.ai_cloudsql_client.id,
    google_project_iam_member.ai_cloudsql_login.id,
    google_sql_provision_script.ai_sessions_revoke_public_connect.id,
    google_sql_provision_script.ai_sessions_schema_grant.id,
  ]
}

# The ai service calls the apis service at DFO_APIS_URL with an ID token
# minted as this runtime account. The grant lives here, beside the account, because the apis stack
# applies first and so cannot name an account this stack creates.
resource "google_cloud_run_v2_service_iam_member" "ai_apis_invoker" {
  project  = var.project_id
  location = var.region
  name     = var.apis_service_name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${module.ai_service.runtime_service_account_email}"
}
