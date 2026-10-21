# Values for this environment that the shared stack code in
# infra/stacks/apis declares with no default.
project_id                          = "dev-fin-observatory"
region                              = "northamerica-northeast1"
namespace                           = "dfo-dev"
cloudsql_login_role_id              = "dfoDevApisCloudsqlLoginOnly"
search_graph_base                   = "https://dfo-dev-dc-datacommons-service-zms5lj4zhq-nn.a.run.app"
datasets_graph_base_url             = "https://dfo-dev-dc-datacommons-service-zms5lj4zhq-nn.a.run.app/core/api"
datasets_sdmx_base_url              = "https://dfo-dev-dc-datacommons-service-zms5lj4zhq-nn.a.run.app/core/api"
graph_dcp_base_url                  = "https://dfo-dev-dc-datacommons-service-zms5lj4zhq-nn.a.run.app/core/api"
dfo_public_site_url                 = "https://dfo-dev-website-staging-zms5lj4zhq-nn.a.run.app" # website output staging_service_url
datacommons_service_name            = "dfo-dev-dc-datacommons-service"
datasets_working_bucket_name        = "dev-fin-observatory-datasets-working"
datasets_pinned_bucket_name         = "dev-fin-observatory-datasets-pinned"
platform_postgres_instance_name     = "dfo-dev-platform-postgres"
platform_postgres_connection_name   = "dev-fin-observatory:northamerica-northeast1:dfo-dev-platform-postgres"
datasets_database_name              = "datasets"
presentation_database_name          = "presentation"
datasets_migrator_secret_id         = "projects/dev-fin-observatory/secrets/dfo-dev-datasets-migrator-password"
presentation_migrator_secret_id     = "projects/dev-fin-observatory/secrets/dfo-dev-presentation-migrator-password"
platform_psc_service_attachment_uri = "projects/fd56baf1868cc60d9p-tp/regions/northamerica-northeast1/serviceAttachments/a-bbd723248b19-psc-service-attachment-e2be3e641f3b4eba"
platform_dns_name                   = "bbd723248b19.3niso0mm9bket.northamerica-northeast1.sql.goog"
dc_spanner_connection_id            = "dfo_dev_dc_spanner_connection"
dc_spanner_instance_id              = "dfo-dev-dc-instance"
dc_spanner_database_id              = "dfo-dev-dc-db"
datasets_migrator_db_user           = "dfo-dev-datasets-migrator"
presentation_migrator_db_user       = "dfo-dev-presentation-migrator"

# Off so destroys and replaces stay unblocked.
stateless_deletion_protection = false

# True keeps the run.app URL open to anonymous callers. It turns false once
# the apis request logs show every caller sending an ID token; see "Caller
# authentication" in infra/dfo-dev/apis/README.md.
allow_unauthenticated = true
# Principals no stack owns, such as a developers' group. The website and ai
# stacks grant their own runtime accounts invoker on this service.
invoker_members = []

# Unpauses the graph release builder's Scheduler trigger and enables its
# alert policies. The deployed dfo-apis image carries graph_release.job.
graph_release_enabled = true

# The builder has published in dev, so the apis service and datasets worker
# load the release.
graph_release_serving = true

# The apis service, datasets worker and search catalogue job serve the code
# index and coverage from the release in place of the coverage artifact.
graph_release_coverage = true

# The origin catalogue is read from the release as well.
graph_release_origin = true

# The builder publishes without diffing each release against the coverage and
# origin catalogue builds.
graph_release_shadow = false

# Jev binds 85 percent of queries, with Gemini as its fallback and on the rest.
# The key is the hand-made dfo-dev-typesafe-api-key secret.
search_binder          = "jev"
search_jev_traffic_pct = 85

# The coverage job, its tick, identities, grants and alerting are gone, and
# no surface gets COVERAGE_ARTIFACT_URI. The services serve coverage from the
# graph release; the coverage bucket stays.
legacy_coverage_pipeline = false

# The graph release builder starts the search catalogue job after each
# publish and the deploy after each deploy, so no Scheduler tick or
# heartbeat alert runs.
search_catalogue_tick = false
