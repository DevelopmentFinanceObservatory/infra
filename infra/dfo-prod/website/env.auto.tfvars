# Values for this environment that the shared stack code in
# infra/stacks/website declares with no default. A commented line is a value
# that exists only after another stack applies; plan fails until it is set.
project_id                        = "prod-fin-observatory"
region                            = "europe-west1"
namespace                         = "dfo-prod"
tier                              = "production"
deployer_service_account          = "dfo-website-deployer@prod-fin-observatory.iam.gserviceaccount.com" # foundation output website_deployer_service_account
cloudsql_login_role_id            = "dfoProdWebsiteCloudsqlLoginOnly"
platform_postgres_instance_name   = "dfo-prod-platform-postgres"                                   # platform output instance_name
platform_postgres_connection_name = "prod-fin-observatory:europe-west1:dfo-prod-platform-postgres" # platform output connection_name
datasets_pin_principal_secret_id  = "dfo-prod-datasets-pin-principal"
live_refresh_principal_secret_id  = "dfo-prod-live-refresh-principal"
caller_principal_secret_id        = "dfo-prod-caller-principal"
caller_hmac_key_secret_id         = "dfo-prod-caller-hmac-key"
# One PostHog project serves every environment; events carry an environment property.
posthog_key = "phc_nNtsVfPvZAKPJ5JagTFzvGsndUddT3PNXguGQsMCnSAt"

platform_psc_service_attachment_uri = "projects/ic74f9d0cb948e2dap-tp/regions/europe-west1/serviceAttachments/a-b588fda303da-psc-service-attachment-18d4894ca2dc23a8" # platform output psc_service_attachment_uri
platform_dns_name                   = "b588fda303da.1b8f7kohjv63q.europe-west1.sql.goog"                                                                              # platform output dns_name
studio_api_base                     = "https://dfo-prod-ai-533754688761.europe-west1.run.app"                                                                         # ai service, deterministic Cloud Run URL
search_api_base                     = "https://dfo-prod-apis-533754688761.europe-west1.run.app"                                                                       # apis service, deterministic Cloud Run URL
apis_service_name                   = "dfo-prod-apis"                                                                                                                 # apis output service_name
# The service's own public origin, which the edge stack serves through
# Cloudflare and the load balancer. Sign-in and OAuth callbacks work on this
# origin only, so each provider's OAuth client lists
# https://developmentfinance.org/api/auth/callback/<provider>.
website_url = "https://developmentfinance.org"

# Behind Cloudflare and the load balancer X-Forwarded-For reads
# "client, cloudflare-edge, lb", so the client sits 2 entries from the right.
trusted_proxy_hops = 2

# Only the edge load balancer reaches the service, and its Cloud Armor policy
# admits only requests carrying Cloudflare's origin secret. A request to the
# run.app URL is refused, so no client can skip Cloudflare's rate limit and
# WAF, or choose its own X-Forwarded-For entry at the trusted depth.
ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

# Terraform refuses to destroy or replace this stack's Cloud Run services and Jobs.
stateless_deletion_protection = true

# One warm instance, so no visitor waits for a cold start. cpu_idle bills it
# at the idle rate between requests.
min_instances = 1

# The role in ONE's SES account that sends sign-in email. It trusts only
# dfo-prod-website-run, and only with this token audience.
ses = {
  role_arn       = "arn:aws:iam::961128127831:role/development-finance-observatory-ses-sender-production"
  region         = "us-east-1"
  token_audience = "development-finance-observatory-production"
}

# Cloudflare Turnstile widget "DFO website production" in the ONE Campaign
# account, for developmentfinance.org. Public: the login page renders it.
turnstile_site_key = "0x4AAAAAAFiLPXQeqPLKYQs9"

# The event export dataset, ID hashing key, Job and hourly trigger (event_export.tf).
event_export_enabled = true
