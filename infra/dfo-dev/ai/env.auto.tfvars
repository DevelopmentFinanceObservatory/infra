# Values for this environment that the shared stack code in
# infra/stacks/ai declares with no default.
project_id                               = "dev-fin-observatory"
region                                   = "northamerica-northeast1"
namespace                                = "dfo-dev"
cloudsql_login_role_id                   = "dfoDevAiCloudsqlLoginOnly"
dfo_apis_url                             = "https://dfo-dev-apis-zms5lj4zhq-nn.a.run.app"
datasets_first_party_principal_secret_id = "dfo-dev-datasets-first-party-principal"
presentation_public_url                  = "https://dfo-dev-website-staging-zms5lj4zhq-nn.a.run.app/mcp/presentation"
platform_postgres_instance_name          = "dfo-dev-platform-postgres"
platform_postgres_connection_name        = "dev-fin-observatory:northamerica-northeast1:dfo-dev-platform-postgres"
platform_psc_service_attachment_uri      = "projects/fd56baf1868cc60d9p-tp/regions/northamerica-northeast1/serviceAttachments/a-bbd723248b19-psc-service-attachment-e2be3e641f3b4eba"
platform_dns_name                        = "bbd723248b19.3niso0mm9bket.northamerica-northeast1.sql.goog"
studio_token_readers = [
  "user:mason@ode.partners",
  "user:mikolaj@ode.partners",
  "user:krzysiek@ode.partners",
]

# Off so destroys and replaces stay unblocked.
stateless_deletion_protection = false
