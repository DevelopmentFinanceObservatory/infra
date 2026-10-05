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

# platform_psc_service_attachment_uri = "" # from platform output psc_service_attachment_uri after apply
# platform_dns_name                   = "" # from platform output dns_name after apply
# studio_api_base                     = "" # from ai output service_url after apply
# search_api_base                     = "" # from apis output service_url after apply
# The service's own public origin, needed on its first apply. Cloud Run's
# deterministic URL is https://dfo-prod-website-<project number>.europe-west1.run.app.
# website_url = ""

# Terraform refuses to destroy or replace this stack's Cloud Run services and Jobs.
stateless_deletion_protection = true
