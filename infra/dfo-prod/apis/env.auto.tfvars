# Values for this environment that the shared stack code in
# infra/stacks/apis declares with no default. A commented line is a value
# that exists only after another stack applies; plan fails until it is set.
project_id                        = "prod-fin-observatory"
region                            = "europe-west1"
namespace                         = "dfo-prod"
cloudsql_login_role_id            = "dfoProdApisCloudsqlLoginOnly"
datacommons_service_name          = "dfo-prod-dc-datacommons-service"
datasets_working_bucket_name      = "prod-fin-observatory-datasets-working"
datasets_pinned_bucket_name       = "prod-fin-observatory-datasets-pinned"
platform_postgres_instance_name   = "dfo-prod-platform-postgres"
platform_postgres_connection_name = "prod-fin-observatory:europe-west1:dfo-prod-platform-postgres"
datasets_database_name            = "datasets"
presentation_database_name        = "presentation"
datasets_migrator_secret_id       = "projects/prod-fin-observatory/secrets/dfo-prod-datasets-migrator-password"
presentation_migrator_secret_id   = "projects/prod-fin-observatory/secrets/dfo-prod-presentation-migrator-password"
dc_spanner_connection_id          = "dfo_prod_dc_spanner_connection"
dc_spanner_instance_id            = "dfo-prod-dc-instance"
dc_spanner_database_id            = "dfo-prod-dc-db"
datasets_migrator_db_user         = "dfo-prod-datasets-migrator"
presentation_migrator_db_user     = "dfo-prod-presentation-migrator"

# search_graph_base                   = "" # from dcp output datacommons_service_url after apply
# datasets_graph_base_url             = "" # from dcp output datacommons_service_url after apply, plus /core/api
# datasets_sdmx_base_url              = "" # from dcp output datacommons_service_url after apply, plus /core/api
# graph_dcp_base_url                  = "" # from dcp output datacommons_service_url after apply, plus /core/api
# dfo_public_site_url                 = "" # the website stack's website_url once it is set
# platform_psc_service_attachment_uri = "" # from platform output psc_service_attachment_uri after apply
# platform_dns_name                   = "" # from platform output dns_name after apply

# Terraform refuses to destroy or replace this stack's Cloud Run services and Jobs.
stateless_deletion_protection = true
