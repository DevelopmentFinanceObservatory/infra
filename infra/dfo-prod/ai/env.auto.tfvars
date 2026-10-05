# Values for this environment that the shared stack code in
# infra/stacks/ai declares with no default. A commented line is a value that
# exists only after another stack applies; plan fails until it is set.
project_id                               = "prod-fin-observatory"
region                                   = "europe-west1"
namespace                                = "dfo-prod"
cloudsql_login_role_id                   = "dfoProdAiCloudsqlLoginOnly"
datasets_first_party_principal_secret_id = "dfo-prod-datasets-first-party-principal"
platform_postgres_instance_name          = "dfo-prod-platform-postgres"                                   # platform output instance_name
platform_postgres_connection_name        = "prod-fin-observatory:europe-west1:dfo-prod-platform-postgres" # platform output connection_name

# Placeholder: the people who call the studio routes from their own machines,
# as "user:<email>". Empty grants no one.
studio_token_readers = []

# dfo_apis_url                        = "" # from apis output service_url after apply
# platform_psc_service_attachment_uri = "" # from platform output psc_service_attachment_uri after apply
# platform_dns_name                   = "" # from platform output dns_name after apply
# The website's public origin plus /mcp/presentation. The website applies
# after this stack, so use its deterministic Cloud Run URL,
# https://dfo-prod-website-<project number>.europe-west1.run.app/mcp/presentation.
# presentation_public_url = ""

# Terraform refuses to destroy or replace this stack's Cloud Run services and Jobs.
stateless_deletion_protection = true
