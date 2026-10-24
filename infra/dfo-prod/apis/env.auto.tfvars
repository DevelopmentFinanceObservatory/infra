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

search_graph_base                   = "https://dfo-prod-dc-datacommons-service-533754688761.europe-west1.run.app"                                                     # dcp service, deterministic Cloud Run URL
datasets_graph_base_url             = "https://dfo-prod-dc-datacommons-service-533754688761.europe-west1.run.app/core/api"                                            # dcp service plus /core/api
datasets_sdmx_base_url              = "https://dfo-prod-dc-datacommons-service-533754688761.europe-west1.run.app/core/api"                                            # dcp service plus /core/api
graph_dcp_base_url                  = "https://dfo-prod-dc-datacommons-service-533754688761.europe-west1.run.app/core/api"                                            # dcp service plus /core/api
dfo_public_site_url                 = "https://developmentfinance.org"                                                                                                # website stack website_url
platform_psc_service_attachment_uri = "projects/ic74f9d0cb948e2dap-tp/regions/europe-west1/serviceAttachments/a-b588fda303da-psc-service-attachment-18d4894ca2dc23a8" # platform output psc_service_attachment_uri
platform_dns_name                   = "b588fda303da.1b8f7kohjv63q.europe-west1.sql.goog"                                                                              # platform output dns_name

# Terraform refuses to destroy or replace this stack's Cloud Run services and Jobs.
stateless_deletion_protection = true

# One warm datasets worker, so the first download after an idle spell starts
# at once. cpu_idle bills it at the idle rate between operations.
datasets_worker_min_instances = 1

# True keeps the run.app URL open to anonymous callers. It turns false once
# the apis request logs show every caller sending an ID token; see "Caller
# authentication" in infra/dfo-dev/apis/README.md.
allow_unauthenticated = true
# Principals no stack owns, such as a developers' group. The website and ai
# stacks grant their own runtime accounts invoker on this service.
invoker_members = []

# One Gemini key per caller, each from its own AI Studio project.
gemini_api_key_secret_id                  = "dfo-prod-apis-gemini-api-key"
search_catalogue_gemini_api_key_secret_id = "dfo-prod-search-catalogue-gemini-api-key"

# Jev binds every query, with Gemini as its fallback.
# The key is the hand-made dfo-prod-typesafe-api-key secret.
search_binder = "jev"

# Unpauses the graph release builder's Scheduler trigger and enables its
# alert policies. The deployed dfo-apis image carries graph_release.job.
graph_release_enabled = true

# The builder has published in prod, so the apis service, the datasets worker,
# the maintenance job and the search catalogue job get GRAPH_RELEASE_URI,
# which dfo-apis needs to start.
graph_release_serving = true

# The apis service, datasets worker and search catalogue job serve the code
# index and coverage from the release in place of the coverage artifact.
graph_release_coverage = true

# The origin catalogue is read from the release as well.
graph_release_origin = true

# The builder publishes without diffing each release against the coverage and
# origin catalogue builds.
graph_release_shadow = false

# The coverage job, its tick, identities, grants and alerting are gone, and
# no surface gets COVERAGE_ARTIFACT_URI. The services serve coverage from the
# graph release; the coverage bucket stays.
legacy_coverage_pipeline = false

# The graph release builder starts the search catalogue job after each
# publish and the deploy after each deploy, so no Scheduler tick or
# heartbeat alert runs.
search_catalogue_tick = false

# The telemetry stack's email channel, built from the alerts object in
# dfo-prod-telemetry-principals. Every apis alert policy notifies it.
alert_notification_channel = "Telemetry pipeline alerts: team"
