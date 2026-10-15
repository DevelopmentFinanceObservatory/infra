terraform {
  # 1.11 for the write-only arguments in auth_secret.tf.
  required_version = ">= 1.11"

  required_providers {
    google = {
      # google_sql_provision_script was introduced in 7.24.0, so that is the honest floor. dcp's 6.23 understates it and holds only through its lock file.
      source  = "hashicorp/google"
      version = ">= 7.24.0"
    }
    random = {
      # 3.7.0 for the ephemeral random_password in auth_secret.tf.
      source  = "hashicorp/random"
      version = ">= 3.7.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  # Staging names carry the tier, production names none: dfo-dev-website-staging
  # in dfo-dev, dfo-prod-website in dfo-prod. The short form serves ids capped
  # at 30 characters (google_service_account.website_migrator).
  tier_suffix       = { staging = "-staging", production = "" }[var.tier]
  tier_suffix_short = { staging = "-stg", production = "" }[var.tier]

  # Prefix for the service and its secrets and Job.
  website_name = "${var.namespace}-website${local.tier_suffix}"
}

resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "dns.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

# This stack's private network path to the shared Cloud SQL instance in
# the platform stack. The instance authorises this project on its side. This
# is the other half. See infra/modules/consumer-psc-network/README.md for
# the subnet range assignment and the no-NAT/no-firewall rationale.
module "psc_network" {
  source = "../../modules/consumer-psc-network"

  project_id = var.project_id
  region     = var.region

  network_name = "${var.namespace}-website-psc"
  subnet_cidr  = "10.100.1.0/24"

  service_attachment_uri = var.platform_psc_service_attachment_uri
  dns_name               = var.platform_dns_name

  depends_on = [google_project_service.apis]
}

# The dfo-website CI image-deployer (provisioned in ../foundation) needs
# actAs on the runtime SA it deploys, and run.developer on the service
# itself, to push image-only revision updates. The module below grants both
# from its deployer_members.
data "google_service_account" "website_deployer" {
  account_id = var.deployer_service_account
}

# The ai stack's studio API token secret, read by secret_id so this plan
# never depends on that stack having applied. See README.
data "google_secret_manager_secret" "studio_api_token" {
  secret_id = "${var.namespace}-studio-api-token"
}

# The ai stack's MCP API token secret, read by secret_id like the studio token above. See README.
data "google_secret_manager_secret" "mcp_api_token" {
  secret_id = "${var.namespace}-mcp-api-token"
}

# dfo-website deploys its `staging` branch to this service in dfo-dev and
# its `main` branch in dfo-prod. The service has its own image-deployer SA
# (above), so only a push to that branch can reach it. See README.md for
# the studio and auth settings below.
module "website_service" {
  source = "../../modules/cloud-run-service"

  project_id          = var.project_id
  region              = var.region
  deletion_protection = var.stateless_deletion_protection
  service_name        = local.website_name
  bootstrap_image     = "gcr.io/cloudrun/hello"
  container_port      = 8080

  ingress = var.ingress

  env_vars = merge({
    WEBSITE_DB_HOST                     = var.platform_dns_name
    WEBSITE_DB_NAME                     = google_sql_database.website.name
    WEBSITE_DB_USER                     = google_sql_user.website_runtime.name
    WEBSITE_DB_INSTANCE_CONNECTION_NAME = var.platform_postgres_connection_name

    # This service's own public origin. See var.website_url.
    BETTER_AUTH_URL = var.website_url

    # The ai harness the /api/studio/* proxy forwards to. See var.studio_api_base.
    STUDIO_API_BASE = var.studio_api_base

    # The apis service the search, datasets and graph proxies forward to. See var.search_api_base.
    SEARCH_API_BASE = var.search_api_base

    # PostHog usage telemetry (project key and EU ingest endpoint). The key is a public write-only token by design, shipped in client-side JavaScript on every PostHog site, so it mounts as a plain env var rather than a secret. See README, "PostHog telemetry".
    POSTHOG_KEY  = var.posthog_key
    POSTHOG_HOST = var.posthog_host

    # Which environment this service is, for the environment property on telemetry events. One PostHog project serves every environment, so the events must say which one they came from.
    ENVIRONMENT = var.tier
    },
    # Set only behind a proxy chain. Omitted when null, so the app keeps its default of 0. See var.trusted_proxy_hops.
    var.trusted_proxy_hops == null ? {} : { TRUSTED_PROXY_HOPS = tostring(var.trusted_proxy_hops) },
  )
  # Sign-in provider pairs (GOOGLE_*, GITHUB_*, MICROSOFT_*) come from sign_in_providers.tf.
  secret_env_vars = merge({
    BETTER_AUTH_SECRET = {
      secret_id = google_secret_manager_secret.website_better_auth_secret.secret_id
      # Pinned, not latest, so warm and new instances never disagree on the
      # signing key during a rotation. See README.
      version = google_secret_manager_secret_version.website_better_auth_secret.version
    }
    # Key the /mcp proxy HMACs the client IP with to form the x-dfo-caller header it sends upstream. Pinned like BETTER_AUTH_SECRET. See README and caller_hmac_key.tf.
    CALLER_HMAC_KEY = {
      secret_id = google_secret_manager_secret.website_caller_hmac_key.secret_id
      version   = google_secret_manager_secret_version.website_caller_hmac_key.version
    }
    # Bearer token the studio proxy sends to the harness. Not version-pinned.
    # See README.
    STUDIO_TOKEN = { secret_id = data.google_secret_manager_secret.studio_api_token.secret_id }
    # Bearer token the /mcp proxy sends to the harness's MCP mounts, which refuse a request without it. Not version-pinned. See README.
    MCP_API_TOKEN = { secret_id = data.google_secret_manager_secret.mcp_api_token.secret_id }
    # Slack incoming webhook for feedback submissions. Not version-pinned:
    # values are added out-of-band and the newest must win. See README and
    # feedback_webhook.tf.
    FEEDBACK_SLACK_WEBHOOK_URL = { secret_id = google_secret_manager_secret.website_feedback_slack_webhook.secret_id }
    # Bearer value the app sends as x-dfo-principal on its server-side
    # datasets pin call. The apis stack owns and pins the secret; this
    # mount reads latest, since this stack holds no version resource of
    # its own to pin against. See README.
    DFO_PRINCIPAL = { secret_id = var.datasets_pin_principal_secret_id }
    # Bearer value the app sends server-side on the frame refresh and render
    # calls a live Studio share makes to dfo-apis and dfo-ai. Unset, the
    # website offers no Live Data option. The apis stack owns and pins the secret.
    # This mount reads latest, as for DFO_PRINCIPAL above. See README.
    LIVE_REFRESH_PRINCIPAL = { secret_id = var.live_refresh_principal_secret_id }
  }, local.sign_in_secret_env_vars)

  deployer_members = ["serviceAccount:${data.google_service_account.website_deployer.email}"]

  min_instances = var.min_instances
  max_instances = 5
  # Combined cap across old and new revisions during a rollout, so the
  # platform stack's max_connections budget holds at the cap.
  service_max_instances = 5
  cpu                   = "1"
  # Next.js holds about 380 MiB at steady state, so a burst of large docs
  # pages pushed a 512Mi instance past its limit.
  memory = "2Gi"
  # The /api/studio/* proxy streams ai agent runs, which that service allows 900s.
  # Matches the ai service so the proxy is never the hop that cuts a long run off.
  timeout_seconds   = 900
  startup_cpu_boost = true
  cpu_idle          = true

  allow_unauthenticated = true # provisional, public until an auth model exists

  vpc_access = {
    network    = module.psc_network.network_id
    subnetwork = module.psc_network.subnetwork_id
  }
}

# The website's server-side proxies call the apis service with an ID token
# minted as this runtime account. The grant lives here, beside the account,
# because the apis stack applies first and so cannot name an account this
# stack creates.
resource "google_cloud_run_v2_service_iam_member" "website_apis_invoker" {
  project  = var.project_id
  location = var.region
  name     = var.apis_service_name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${module.website_service.runtime_service_account_email}"
}
