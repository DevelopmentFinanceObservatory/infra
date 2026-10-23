terraform {
  # 1.11 for the write-only arguments in datasets_first_party_principal.tf,
  # datasets_pin_principal.tf, and live_refresh_principal.tf.
  required_version = ">= 1.11"

  required_providers {
    google = {
      # 7.24.0 introduced google_sql_provision_script (datasets_access.tf),
      # after 6.23.0 added secret_data_wo on google_secret_manager_secret_version.
      source  = "hashicorp/google"
      version = ">= 7.24.0"
    }
    random = {
      # 3.7.0 for the ephemeral random_password in
      # datasets_first_party_principal.tf, datasets_pin_principal.tf, and
      # live_refresh_principal.tf.
      source  = "hashicorp/random"
      version = ">= 3.7.0"
    }
    time = {
      # time_sleep in coverage.tf, closing the gap between a freshly created
      # log-based metric and Cloud Monitoring's own propagation of its
      # descriptor. No specific version feature needed; floored at latest.
      source  = "hashicorp/time"
      version = ">= 0.9.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Every Cloud Scheduler trigger in this stack depends on it: the graph
# release, origin catalogue, search catalogue, coverage and datasets
# maintenance ticks.
resource "google_project_service" "cloudscheduler" {
  project            = var.project_id
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
}

# Reuse the existing Gemini API key secret (not terraform-managed — see
# infra/stacks/dcp/dfo.tf and infra/stacks/ai/main.tf for its other
# consumers) rather than creating a dedicated one for this service.
data "google_secret_manager_secret" "gemini" {
  secret_id = "${var.namespace}-gemini-api-key"
}

# TypeSafe's API key for the Jev binder, created by hand like the Gemini key.
# Read only when search_binder sends calls to Jev.
data "google_secret_manager_secret" "typesafe" {
  count     = var.search_binder == "gemini" ? 0 : 1
  secret_id = "${var.namespace}-typesafe-api-key"
}

# The dfo-apis CI image-deployer (provisioned in ../foundation) needs actAs on
# the runtime SA to push image-only revision updates; it's granted that
# per-SA below.
data "google_service_account" "apis_deployer" {
  account_id = "dfo-apis-deployer@${var.project_id}.iam.gserviceaccount.com"
}

module "apis_service" {
  source = "../../modules/cloud-run-service"

  project_id          = var.project_id
  region              = var.region
  deletion_protection = var.stateless_deletion_protection
  service_name        = "${var.namespace}-apis"
  bootstrap_image     = "gcr.io/cloudrun/hello"
  container_port      = 8080

  secret_env_vars = merge({
    # The engine warm-loads its Gemini client at startup, so a missing or
    # invalid key fails the revision immediately rather than on first request.
    GEMINI_API_KEY = { secret_id = data.google_secret_manager_secret.gemini.secret_id }

    # Authenticates the publish door only (datasets_api.doors.publish) — see
    # datasets_pin_principal.tf for the pin door's own value below.
    DATASETS_FIRST_PARTY_PRINCIPAL = {
      secret_id = google_secret_manager_secret.datasets_first_party_principal.secret_id
      # Pinned rather than latest so warm and new instances can never
      # disagree during a rotation; the pin moves with the version resource,
      # rolling the service in the same apply.
      version = google_secret_manager_secret_version.datasets_first_party_principal.version
    }

    # Authenticates the pin door only (datasets_api.doors.pin), a separate
    # value from DATASETS_FIRST_PARTY_PRINCIPAL above — see
    # datasets_pin_principal.tf.
    DATASETS_PIN_FIRST_PARTY_PRINCIPAL = {
      secret_id = google_secret_manager_secret.datasets_pin_principal.secret_id
      # Pinned rather than latest so warm and new instances can never
      # disagree during a rotation; the pin moves with the version resource,
      # rolling the service in the same apply.
      version = google_secret_manager_secret_version.datasets_pin_principal.version
    }

    # Authenticates the frame refresh and Presentation render routes a live
    # Studio share calls, a separate value from both datasets principals
    # above. See live_refresh_principal.tf.
    LIVE_REFRESH_PRINCIPAL = {
      secret_id = google_secret_manager_secret.live_refresh_principal.secret_id
      # Pinned so warm and new instances never disagree during a rotation.
      # The pin moves with the version resource, rolling the service in the
      # same apply.
      version = google_secret_manager_secret_version.live_refresh_principal.version
    }
    }, {
    # Mounted only when search_binder sends calls to Jev, so a gemini
    # environment needs no TypeSafe secret.
    for name, secret_id in { TYPESAFE_API_KEY = one(data.google_secret_manager_secret.typesafe[*].secret_id) } :
    name => { secret_id = secret_id } if var.search_binder != "gemini"
  })

  env_vars = merge({
    # The project Cloud Logging's trace field names. dfo-apis writes JSON log
    # lines carrying logging.googleapis.com/trace, which needs it, and Cloud
    # Run does not set it.
    GOOGLE_CLOUD_PROJECT = var.project_id

    SEARCH_GRAPH_BASE   = var.search_graph_base
    SEARCH_ENGINE_MODEL = var.search_engine_model
    DFO_CORS_ORIGINS    = var.dfo_cors_origins

    # TYPESAFE_API_KEY above is mounted whenever SEARCH_BINDER is not gemini.
    SEARCH_BINDER          = var.search_binder
    SEARCH_JEV_TRAFFIC_PCT = tostring(var.search_jev_traffic_pct)

    DATASETS_GRAPH_BASE_URL = var.datasets_graph_base_url
    DATASETS_SDMX_BASE_URL  = var.datasets_sdmx_base_url

    # The UN System Data Commons for every surface, from the variable the
    # origin catalogue job reads too (origin_catalogue.tf).
    UN_GRAPH_BASE_URL = var.un_graph_base_url

    # dfo-apis mounts the Datasets surface only when this reads "1" or
    # "true". Every other value, including unset, leaves it unmounted.
    DFO_DATASETS_SURFACE = var.dfo_datasets_surface

    GRAPH_DCP_BASE_URL = var.graph_dcp_base_url

    # Concurrent DCP reads the Graph surface runs on each instance. The
    # dfo-apis default of 4 is filled by a burst of the website's source
    # documentation reads.
    GRAPH_NODE_POOL_SIZE = "16"

    # dfo-apis mounts the Graph surface only when this reads "1" or "true".
    # Every other value, including unset, leaves it unmounted. Its lifespan
    # requires GRAPH_DCP_BASE_URL above to already be set, or the service
    # fails to serve any request at all, not just Graph requests.
    DFO_GRAPH_SURFACE = var.dfo_graph_surface

    # Full Cloud Run resource name of the DC service, whose serving revision
    # dfo-apis reads as its graph-generation cache token. Built from the same
    # var.datacommons_service_name that graph_generation_access.tf grants on.
    DFO_GRAPH_GENERATION_SERVICE = "projects/${var.project_id}/locations/${var.region}/services/${var.datacommons_service_name}"

    # dfo-apis mounts the Skills surface at /api/skills only when this reads
    # "1" or "true". Every other value, including unset, leaves it unmounted.
    # The surface reuses Search's graph client, so this is its only variable.
    DFO_SKILLS_SURFACE = var.dfo_skills_surface

    # The same variables datasets_access.tf's bucket grants target, so the
    # env var and the grant always name one bucket.
    DATASETS_ARTIFACT_BUCKET_WORKING = var.datasets_working_bucket_name
    DATASETS_ARTIFACT_BUCKET_PINNED  = var.datasets_pinned_bucket_name

    # The runtime database path. Setting the connection name is what routes
    # the app through the Cloud SQL connector rather than plain TCP, and the
    # connector authenticates as the runtime service account over IAM, so
    # there is no password variable here. The username reads the same
    # resource that creates the Postgres role, so the name the app logs in
    # as and the role on the instance stay one value.
    DATASET_STORE_INSTANCE_CONNECTION_NAME = var.platform_postgres_connection_name
    DATASET_STORE_RUNTIME_DB_USER          = google_sql_user.datasets_runtime.name

    # dfo-apis mounts the Presentation surface only when this reads "1" or
    # "true". Every other value, including unset, leaves it unmounted. Its
    # lifespan opens a pool against the presentation database and expects the
    # schema presentation_migrate applies, or the service fails to serve any
    # request at all, not just Presentation requests.
    DFO_PRESENTATION_SURFACE = var.dfo_presentation_surface

    # Same instance as the datasets connection above, and the same runtime
    # Postgres role: Presentation runs inside this same service, as this same
    # runtime service account, so Cloud SQL derives the identical role from
    # its email. No new google_sql_user for it.
    PRESENTATION_STORE_INSTANCE_CONNECTION_NAME = var.platform_postgres_connection_name
    PRESENTATION_STORE_RUNTIME_DB_USER          = google_sql_user.datasets_runtime.name

    # origin_catalogue.tf's bucket. The service raises at startup when no
    # published catalogue can be loaded.
    ORIGIN_CATALOGUE_URI = "gs://${google_storage_bucket.origin_catalogue.name}/"

    # search_catalogue.tf's bucket, which GET /api/search/catalogue serves.
    SEARCH_CATALOGUE_URI = "gs://${google_storage_bucket.search_catalogue.name}/"

    # The website origin every download bundle link is built on. The apis
    # service refuses to start without it, so a missing value fails the
    # revision.
    DFO_PUBLIC_SITE_URL = var.dfo_public_site_url

    # Prints the website's /data?spec=&v= page in dataset bundles whose
    # definition the site can replay. The flag is part of every bundle's
    # rendition token, so turning it on re-renders each bundle once, on its
    # next request.
    DFO_SITE_DATASET_LINKS = "true"

    # datasets_worker.tf. The mint door reads these three to enqueue an
    # over-budget operation: where to dispatch the run request, which
    # identity to mint the OIDC token as, and which queue to enqueue onto.
    # DFO_WORKER_URL reads local.datasets_worker_url rather than
    # google_cloud_run_v2_service.datasets_worker.uri: that same local is
    # what the worker service mounts on itself (it cannot reference its own
    # .uri — see datasets_worker.tf), so this value and the one the worker
    # sees on itself are always the same string by construction.
    DFO_WORKER_URL                     = local.datasets_worker_url
    DFO_WORKER_INVOKER_SERVICE_ACCOUNT = google_service_account.datasets_worker_invoker.email
    DFO_TASKS_QUEUE                    = google_cloud_tasks_queue.datasets_worker.id

    # dfo-apis's deadline for one submission of an operation
    # (datasets_worker.tf), built from the locals the queue's retry_config
    # reads, so it moves with the queue's attempts, backoff and concurrency.
    DATASETS_OPERATION_DEADLINE_SECONDS = tostring(local.datasets_operation_deadline_seconds)

    # The queue's max_attempts (datasets_worker.tf), from the local its
    # retry_config reads.
    DATASETS_OPERATION_MAX_ATTEMPTS = tostring(local.datasets_retry_max_attempts)

    # The backlog dfo-apis admits, which sets the queue wait inside the
    # operation deadline above.
    DATASETS_OPERATION_BACKLOG_MAX = tostring(local.datasets_operation_backlog_max)
    },
    # coverage.tf's bucket, while var.legacy_coverage_pipeline is true. An
    # image without graph_release_coverage raises at startup when this
    # artifact can't be loaded, so a missing or unreadable value fails the
    # revision the same way a bad GEMINI_API_KEY does.
    var.legacy_coverage_pipeline ? { COVERAGE_ARTIFACT_URI = "gs://${google_storage_bucket.coverage.name}/" } : {},
    # graph_release.tf's bucket, once var.graph_release_serving is true. The
    # service loads the release the pointer names at startup and refuses to
    # start when none is published, so it stays unset until the builder has
    # published in this environment.
    var.graph_release_serving ? { GRAPH_RELEASE_URI = "gs://${google_storage_bucket.graph_release.name}/" } : {},
    # Serve the code index and coverage from that release, once
    # var.graph_release_coverage is true.
    var.graph_release_coverage ? { GRAPH_RELEASE_COVERAGE = "1" } : {},
    # Read the origin catalogue from that release too, once
    # var.graph_release_origin is true.
    var.graph_release_origin ? { GRAPH_RELEASE_ORIGIN = "1" } : {}
  )

  deployer_members = ["serviceAccount:${data.google_service_account.apis_deployer.email}"]

  min_instances = 1
  max_instances = 5
  # Combined cap across old and new revisions during a rollout, so the
  # platform stack's max_connections budget holds at the cap.
  service_max_instances = 5
  cpu                   = "1"

  # The coverage-backed Search/Datasets surfaces keep an Arrow index in
  # memory and can temporarily hold both the old and new index during a
  # recheck. The prior 1Gi limit is below measured reload and broad-lookup
  # peaks at the current corpus size. Revisit after the serving index stops
  # rebuilding on unchanged stamps and has a bounded memory profile.
  memory = "4Gi"

  timeout_seconds = 300

  startup_cpu_boost = true
  cpu_idle          = true

  allow_unauthenticated = var.allow_unauthenticated

  # Direct VPC egress onto this stack's own PSC subnet (network.tf) — the path
  # to the shared Cloud SQL instance the Datasets API's grants in
  # datasets_access.tf assume.
  vpc_access = {
    network    = module.psc_network.network_id
    subnetwork = module.psc_network.subnetwork_id
  }
}

# One invoker grant per identity in var.invoker_members. Every other grant sits
# beside the account it names: eval_reader.tf's in the dev apis stack, and the
# website and ai runtime accounts' in those stacks, which apply after this one.
resource "google_cloud_run_v2_service_iam_member" "apis_invoker" {
  for_each = toset(var.invoker_members)
  project  = var.project_id
  location = var.region
  name     = module.apis_service.service_name
  role     = "roles/run.invoker"
  member   = each.value
}

# The tag the apis service is running, read fresh on every plan and
# apply rather than embedded as a literal. This is what coverage.tf,
# datasets_worker.tf, datasets_migrate_job.tf, and presentation_migrate_job.tf
# bootstrap their own resources from instead of each carrying a tag of its
# own: the deploy pipeline always builds one image per commit for the whole
# app, so whatever tag apis is currently serving already carries
# dataset_store, presentation_store, and series_coverage.job alike, and is
# guaranteed to still be in Artifact Registry (Cloud Run couldn't be serving
# it otherwise). A stack that has never seen a real deploy reads this as
# module.apis_service's own "gcr.io/cloudrun/hello" bootstrap placeholder,
# which is expected: that first deploy is a manual bootstrap step regardless
# of what a sibling resource's own image argument reads.
locals {
  live_apis_image = module.apis_service.image
}
