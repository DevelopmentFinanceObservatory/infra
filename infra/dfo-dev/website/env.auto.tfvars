# Values for this environment that the shared stack code in
# infra/stacks/website declares with no default.
project_id                          = "dev-fin-observatory"
region                              = "northamerica-northeast1"
namespace                           = "dfo-dev"
tier                                = "staging"
deployer_service_account            = "dfo-website-staging-deployer@dev-fin-observatory.iam.gserviceaccount.com"
cloudsql_login_role_id              = "dfoDevWebsiteCloudsqlLoginOnly"
platform_psc_service_attachment_uri = "projects/fd56baf1868cc60d9p-tp/regions/northamerica-northeast1/serviceAttachments/a-bbd723248b19-psc-service-attachment-e2be3e641f3b4eba"
platform_dns_name                   = "bbd723248b19.3niso0mm9bket.northamerica-northeast1.sql.goog"
platform_postgres_instance_name     = "dfo-dev-platform-postgres"
platform_postgres_connection_name   = "dev-fin-observatory:northamerica-northeast1:dfo-dev-platform-postgres"
studio_api_base                     = "https://dfo-dev-ai-zms5lj4zhq-nn.a.run.app"
search_api_base                     = "https://dfo-dev-apis-zms5lj4zhq-nn.a.run.app"
apis_service_name                   = "dfo-dev-apis" # apis output service_name
website_url                         = "https://dfo-dev-website-staging-zms5lj4zhq-nn.a.run.app"
datasets_pin_principal_secret_id    = "dfo-dev-datasets-pin-principal"
live_refresh_principal_secret_id    = "dfo-dev-live-refresh-principal"
posthog_key                         = "phc_nNtsVfPvZAKPJ5JagTFzvGsndUddT3PNXguGQsMCnSAt"

# Off so destroys and replaces stay unblocked.
stateless_deletion_protection = false

# The role in ONE's SES account that sends sign-in email. It trusts only
# dfo-dev-website-staging-run, and only with this token audience. Staging
# sends real mail from studio@developmentfinance.org, so use test recipients.
ses = {
  role_arn       = "arn:aws:iam::961128127831:role/development-finance-observatory-ses-sender-staging"
  region         = "us-east-1"
  token_audience = "development-finance-observatory-staging"
}

# Cloudflare Turnstile widget "DFO website staging" in the ONE Campaign
# account, for this service's run.app host. Public: the login page renders it.
turnstile_site_key = "0x4AAAAAAFiLWYsFJwHodJgu"
