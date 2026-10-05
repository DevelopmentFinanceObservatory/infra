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
# One PostHog project serves every environment; events carry an environment property.
posthog_key = "phc_nNtsVfPvZAKPJ5JagTFzvGsndUddT3PNXguGQsMCnSAt"

platform_psc_service_attachment_uri = "projects/ic74f9d0cb948e2dap-tp/regions/europe-west1/serviceAttachments/a-b588fda303da-psc-service-attachment-18d4894ca2dc23a8" # platform output psc_service_attachment_uri
platform_dns_name                   = "b588fda303da.1b8f7kohjv63q.europe-west1.sql.goog"                                                                              # platform output dns_name
studio_api_base                     = "https://dfo-prod-ai-533754688761.europe-west1.run.app"                                                                         # ai service, deterministic Cloud Run URL
search_api_base                     = "https://dfo-prod-apis-533754688761.europe-west1.run.app"                                                                       # apis service, deterministic Cloud Run URL
# The service's own public origin, needed on its first apply. Cloud Run's
# deterministic URL is https://dfo-prod-website-<project number>.europe-west1.run.app.
website_url = "https://dfo-prod-website-533754688761.europe-west1.run.app" # this service, deterministic Cloud Run URL

# Terraform refuses to destroy or replace this stack's Cloud Run services and Jobs.
stateless_deletion_protection = true
