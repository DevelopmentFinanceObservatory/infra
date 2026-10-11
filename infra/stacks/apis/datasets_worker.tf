# The async worker: a second Cloud Run service that runs one over-budget
# Datasets mint per instance, dispatched by Cloud Tasks with an OIDC token.
# A mint over the synchronous budget returns 202 with an operation id
# instead of running inline; the mint door enqueues a task naming that id,
# and the worker claims the corresponding leased row in `datasets.operation`
# before running the same materialisation path the synchronous door runs.
#
# Declared directly rather than through ../../modules/cloud-run-service: that
# module always mints a dedicated runtime service account and has no ingress
# input, and this service needs restricted ingress — the same divergence
# datasets_migrate_job.tf and presentation_migrate_job.tf already have from
# the module for Jobs, which the module doesn't model at all. The service
# resource below mirrors the module's shape (dedicated deployer actAs and
# run.developer, the same image-ownership lifecycle.ignore_changes) by hand.

# Project number for the deterministic Cloud Run URL local below —
# google_cloud_run_v2_service.datasets_worker.uri is a project-id-based
# random-hash URL that only resolves after the service exists, not the
# project-number form this stack builds by hand.
data "google_project" "current" {
  project_id = var.project_id
}

# The worker's own service needs DFO_WORKER_URL on itself (env block below),
# but google_cloud_run_v2_service.datasets_worker.uri is an attribute of
# this same resource — referencing it from within the resource's own
# configuration is a dependency cycle Terraform refuses to plan. Cloud Run
# publishes a second, deterministic URL form that can be computed without
# waiting on the resource to exist:
# "https://[TAG---]SERVICE_NAME-PROJECT_NUMBER.REGION.run.app" ("Invoke with
# an HTTPS request", https://cloud.google.com/run/docs/triggering/https-request).
# No traffic tag applies here, so the TAG--- segment is omitted. The DNS
# segment (service name + project number) has a 63-character ceiling per
# that same page; "dfo-dev-datasets-worker" plus a 12-digit project number
# is 36 characters, well clear of it. main.tf's DFO_WORKER_URL reads this
# same local rather than google_cloud_run_v2_service.datasets_worker.uri, so
# the value the worker sees on itself and the value the apis service
# dispatches to can never disagree.
locals {
  datasets_worker_service_name = "${var.namespace}-datasets-worker"
  datasets_worker_url          = "https://${local.datasets_worker_service_name}-${data.google_project.current.number}.${var.region}.run.app"

  # Read by the Cloud Tasks queue's rate_limits.max_concurrent_dispatches
  # below.
  datasets_worker_dispatch_concurrency = 4

  # dfo-apis gives each claimed operation a static lease of
  # run_deadline_seconds from claimed_at: a 1,500 s work deadline plus 120 s
  # of grace for the tail of the run. A delivery inside the lease answers 409;
  # only a delivery after claimed_at + this many seconds can re-claim. The
  # retry_config below derives its bounds from this value.
  datasets_operation_run_deadline_seconds = 1620

  # The dispatch_deadline dfo-apis sets on every task, Cloud Tasks' ceiling
  # for an HTTP target.
  datasets_dispatch_deadline_seconds = 1800

  # Slack added to the lease in min_backoff, so clock skew between Cloud
  # Tasks and Postgres cannot put the first retry inside the lease.
  datasets_retry_margin_seconds = 60

  datasets_retry_max_attempts = 3

  # Gap between attempts: the lease plus the margin, constant (max_backoff
  # equals min_backoff, max_doublings is 0).
  datasets_retry_backoff_seconds = local.datasets_operation_run_deadline_seconds + local.datasets_retry_margin_seconds

  # The most operations dfo-apis admits as queued or running at once. It
  # refuses a mint over this backlog.
  datasets_operation_backlog_max = 20

  # Wait of one delivery for a dispatch slot behind a full backlog, which
  # drains max_concurrent_dispatches at a time, each batch taking up to a
  # dispatch deadline. Retries of other tasks compete for the same slots, so
  # every delivery of a task can meet this wait, not only the first.
  datasets_queue_wait_seconds = ceil(local.datasets_operation_backlog_max / local.datasets_worker_dispatch_concurrency) * local.datasets_dispatch_deadline_seconds

  # dfo-apis's own deadline for one submission of an operation, read as
  # DATASETS_OPERATION_DEADLINE_SECONDS and counted from the dispatch. An
  # operation still unfinished after it fails retryable at the next poll, a
  # delivery that arrives later answers the failed row without running, and
  # the backlog stops counting the row. It is an application deadline and says
  # nothing about what the queue still holds. The value lets every delivery
  # wait behind a full backlog and then run to its dispatch deadline, with the
  # backoff between deliveries and a margin:
  # 3 * (9,000 + 1,800) + 2 * 1,680 + 240 = 36,000 s.
  datasets_operation_deadline_seconds = (local.datasets_retry_max_attempts * (local.datasets_queue_wait_seconds + local.datasets_dispatch_deadline_seconds)
  + (local.datasets_retry_max_attempts - 1) * local.datasets_retry_backoff_seconds + 240)
}

# A dedicated runtime identity for the worker, distinct from the apis runtime
# identity above. The apis runtime SA holds roles/secretmanager.secretAccessor
# on GEMINI_API_KEY, DATASETS_FIRST_PARTY_PRINCIPAL and
# DATASETS_PIN_FIRST_PARTY_PRINCIPAL (main.tf's module.apis_service
# secret_env_vars grants these automatically), none of which the worker's own
# env sets or has a reason to read — the worker mounts only
# POST /internal/datasets/operations/{id}/run, never a public door. This
# account carries only what that one path needs: Cloud SQL login, the
# datasets working/pinned and coverage buckets, and signBlob on itself; see
# the grants declared below.
resource "google_service_account" "datasets_worker" {
  project      = var.project_id
  account_id   = "${var.namespace}-datasets-worker-run"
  display_name = "Datasets async worker runtime"
}

# ─────────────────────────────────────────────────────────────────────────────
# Worker identity access
# ─────────────────────────────────────────────────────────────────────────────

# Bucket access, mirroring datasets_access.tf's grants for the apis runtime
# identity exactly: the worker runs the same mint path (fetch, store,
# promote) that the synchronous door runs, so it needs the same
# create/view — never delete — on both buckets.
resource "google_storage_bucket_iam_member" "datasets_worker_working_creator" {
  bucket = var.datasets_working_bucket_name
  role   = "roles/storage.objectCreator"
  member = google_service_account.datasets_worker.member
}

resource "google_storage_bucket_iam_member" "datasets_worker_working_viewer" {
  bucket = var.datasets_working_bucket_name
  role   = "roles/storage.objectViewer"
  member = google_service_account.datasets_worker.member
}

resource "google_storage_bucket_iam_member" "datasets_worker_pinned_creator" {
  bucket = var.datasets_pinned_bucket_name
  role   = "roles/storage.objectCreator"
  member = google_service_account.datasets_worker.member
}

resource "google_storage_bucket_iam_member" "datasets_worker_pinned_viewer" {
  bucket = var.datasets_pinned_bucket_name
  role   = "roles/storage.objectViewer"
  member = google_service_account.datasets_worker.member
}

# Read-only on the coverage bucket, mirroring coverage.tf's
# coverage_apis_runtime_viewer grant: worker_app.py builds DefinitionDeps
# including series_coverage.shared.get_coverage_service(), so the worker
# reads the published coverage artifact the same way the synchronous door
# does, and never writes to this bucket.
resource "google_storage_bucket_iam_member" "datasets_worker_coverage_viewer" {
  bucket = google_storage_bucket.coverage.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.datasets_worker.member
}

# Cloud SQL IAM access, mirroring datasets_access.tf's
# datasets_cloudsql_client/datasets_cloudsql_instance_user grants exactly —
# same rationale (cloudsql.client to open a connection, the login-only custom
# role rather than roles/cloudsql.instanceUser to keep the Cloud SQL Data
# API's executeSql permission off this identity too).
resource "google_project_iam_member" "datasets_worker_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.datasets_worker.member
}

resource "google_project_iam_member" "datasets_worker_cloudsql_instance_user" {
  project = var.project_id
  role    = google_project_iam_custom_role.cloudsql_login_only.id
  member  = google_service_account.datasets_worker.member
}

# Database user, mirroring datasets_access.tf's google_sql_user.datasets_runtime
# exactly — the worker's own identity, authenticating over IAM rather than a
# stored password.
resource "google_sql_user" "datasets_worker_runtime" {
  name     = trimsuffix(google_service_account.datasets_worker.email, ".gserviceaccount.com")
  instance = var.platform_postgres_instance_name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"

  deletion_policy = "ABANDON"
}

# This account's schema access comes from dataset_store migration
# 0012_worker_role.sql, which grants it membership in the runtime role
# ({{RUNTIME_DB_USER}}) so it inherits that role's schema privileges --
# 0001_bootstrap.sql's USAGE/SELECT/INSERT/UPDATE/DELETE/sequence grants
# and anything a future migration grants the runtime role via
# ALTER DEFAULT PRIVILEGES. No separate schema-level grant is declared
# here: Postgres privileges are dataset_store's own migration's concern,
# not this stack's.

# signBlob on itself, mirroring datasets_access.tf's datasets_token_creator
# grant: worker.py::run_operation calls the same
# datasets_api.serve.serve_definition/serve_collection entry the synchronous
# mint door calls, which calls render.py::_store_artifact, which calls
# artifact_store.signed_get_url — a Cloud Run SA has no downloadable key, so
# V4 signed URLs go through the IAM signBlob API instead.
resource "google_service_account_iam_member" "datasets_worker_token_creator" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${google_service_account.datasets_worker.email}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.datasets_worker.email}"
}

# actAs so the deployer can attach this identity to the service below, the
# same grant coverage.tf and datasets_access.tf make for their own dedicated
# identities.
resource "google_service_account_iam_member" "datasets_worker_deployer_act_as" {
  service_account_id = google_service_account.datasets_worker.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${data.google_service_account.apis_deployer.email}"
}

output "datasets_worker_runtime_service_account_email" {
  description = "Email of the worker's own runtime identity — distinct from the apis service's runtime SA, granted no secret access."
  value       = google_service_account.datasets_worker.email
}

# ─────────────────────────────────────────────────────────────────────────────
# APIs
# ─────────────────────────────────────────────────────────────────────────────

resource "google_project_service" "cloudtasks" {
  project            = var.project_id
  service            = "cloudtasks.googleapis.com"
  disable_on_destroy = false
}

# ─────────────────────────────────────────────────────────────────────────────
# Service
# ─────────────────────────────────────────────────────────────────────────────

# Bootstrap only, the same placeholder module.apis_service itself bootstraps
# from (main.tf), not local.live_apis_image: unlike the coverage and migrate
# Jobs, creating this Service starts a revision that has to actually serve
# traffic immediately, and local.live_apis_image can be an image that
# predates the worker surface entirely -- one that doesn't listen on 8080
# under this container's env at all, rather than one that merely lacks a
# Python module a Job would only hit on execution. gcr.io/cloudrun/hello
# answers any request with a fixed 200, which is enough until the deploy
# pipeline's image-only `gcloud run services update --image` call points
# this at a real dfo-apis image.
variable "datasets_worker_bootstrap_image" {
  description = "Image the worker service is created with. The deploy pipeline replaces it with an image-only `gcloud run services update --image` call before it starts routing tasks."
  type        = string
  default     = "gcr.io/cloudrun/hello"
}

# Runs as google_service_account.datasets_worker, a dedicated identity
# distinct from module.apis_service.runtime_service_account_email — the same
# rationale coverage.tf's google_service_account.coverage_job comment states:
# this workload's access shape (Cloud SQL write to the datasets schema,
# working/pinned/coverage bucket access, signBlob on itself) is not the shape
# the public, unauthenticated serving identity needs to also carry via
# inherited grants like the secrets above.
resource "google_cloud_run_v2_service" "datasets_worker" {
  name     = local.datasets_worker_service_name
  location = var.region
  project  = var.project_id

  deletion_protection = var.stateless_deletion_protection

  # Combined cap across old and new revisions during a rollout, so the
  # platform stack's max_connections budget holds at the cap. The template's
  # max_instance_count below bounds each revision on its own.
  scaling {
    max_instance_count = 4
  }

  # Ingress restricted to internal traffic: Cloud Tasks dispatching from the
  # same project counts as internal, and there is no allUsers invoker below
  # — see google_cloud_run_v2_service_iam_member.datasets_worker_invoker.
  # This is the second, network-level layer; the app itself verifies the
  # OIDC token's audience and email as well, and a test asserts the API app
  # never mounts /internal/* while the worker app mounts nothing else.
  ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account = google_service_account.datasets_worker.email

    scaling {
      min_instance_count = var.datasets_worker_min_instances
      # Matches the Cloud Tasks queue's max_concurrent_dispatches below: one
      # operation per instance (concurrency 1), so four concurrent
      # dispatches need four instances to avoid queueing behind Cloud Run
      # rather than Cloud Tasks.
      max_instance_count = 4
    }

    # One in-flight mint per instance. A materialise run holds Frame chunks,
    # writer buffers and an SDMX fetch in memory for the lifetime of the
    # operation; a second concurrent request on the same instance would
    # double every one of those budgets.
    max_instance_request_concurrency = 1

    # Cloud Tasks' own HTTP dispatch_deadline caps at 1800s (30 minutes);
    # the app sets that per task, not here. This is the container-side
    # timeout, set just above it so Cloud Run never cancels a request Cloud
    # Tasks is still willing to wait on.
    timeout = "1860s"

    containers {
      image = var.datasets_worker_bootstrap_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "2"
          memory = "4Gi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      # Mounts only POST /internal/datasets/operations/{id}/run — no
      # Search, Datasets-public, Graph or Presentation surface, and no
      # GEMINI_API_KEY or DATASETS_FIRST_PARTY_PRINCIPAL/PIN secret: the
      # worker is driven by Cloud Tasks and Postgres state, never by a
      # public-facing door.
      env {
        name  = "DFO_WORKER_SURFACE"
        value = "1"
      }

      # The project Cloud Logging's trace field names, as on the apis service
      # (main.tf). Cloud Run does not set it; without it the worker's log
      # lines carry no trace field.
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }

      # Full Cloud Run resource name of the DC service, whose serving
      # revision the worker's graph-derived caches key on, as on the apis
      # service (main.tf). The worker's runtime account reads it under the
      # grant in graph_generation_access.tf; without the variable every cache
      # runs under the unknown generation.
      env {
        name  = "DFO_GRAPH_GENERATION_SERVICE"
        value = "projects/${var.project_id}/locations/${var.region}/services/${var.datacommons_service_name}"
      }

      # The same datasets env the service reads (main.tf), so a mint that
      # runs on the worker fetches, stores and prices identically to one
      # that ran synchronously.
      env {
        name  = "DATASETS_GRAPH_BASE_URL"
        value = var.datasets_graph_base_url
      }

      env {
        name  = "DATASETS_SDMX_BASE_URL"
        value = var.datasets_sdmx_base_url
      }

      env {
        name  = "UN_GRAPH_BASE_URL"
        value = var.un_graph_base_url
      }

      # The worker runs the same app factory as the service, and
      # dfo_apis.app imports the search engine, whose settings refuse to
      # load without this value. The worker never serves search.
      env {
        name  = "SEARCH_GRAPH_BASE"
        value = var.search_graph_base
      }

      env {
        name  = "DATASETS_ARTIFACT_BUCKET_WORKING"
        value = var.datasets_working_bucket_name
      }

      env {
        name  = "DATASETS_ARTIFACT_BUCKET_PINNED"
        value = var.datasets_pinned_bucket_name
      }

      env {
        name  = "DATASET_STORE_INSTANCE_CONNECTION_NAME"
        value = var.platform_postgres_connection_name
      }

      env {
        name  = "DATASET_STORE_RUNTIME_DB_USER"
        value = google_sql_user.datasets_worker_runtime.name
      }

      env {
        name  = "COVERAGE_ARTIFACT_URI"
        value = "gs://${google_storage_bucket.coverage.name}/"
      }

      env {
        name  = "ORIGIN_CATALOGUE_URI"
        value = "gs://${google_storage_bucket.origin_catalogue.name}/"
      }

      # The same website origin main.tf mounts: the worker builds a bundle's
      # links on it and refuses to start without it.
      env {
        name  = "DFO_PUBLIC_SITE_URL"
        value = var.dfo_public_site_url
      }

      # The same dataset-link flag main.tf mounts, so a bundle the worker
      # renders matches one the apis service renders.
      env {
        name  = "DFO_SITE_DATASET_LINKS"
        value = "true"
      }

      # The same two values main.tf mounts on the apis service so the mint
      # door can enqueue a task — the worker's shared config module reads
      # both unconditionally regardless of which surface is running, so
      # DFO_WORKER_SURFACE alone does not exempt this service from setting
      # them. local.datasets_worker_url avoids the self-reference cycle
      # documented above this resource.
      env {
        name  = "DFO_WORKER_URL"
        value = local.datasets_worker_url
      }

      env {
        name  = "DFO_WORKER_INVOKER_SERVICE_ACCOUNT"
        value = google_service_account.datasets_worker_invoker.email
      }

      # dfo-apis's deadline for one submission of an operation, the same value
      # the apis service reads.
      env {
        name  = "DATASETS_OPERATION_DEADLINE_SECONDS"
        value = tostring(local.datasets_operation_deadline_seconds)
      }

      # The queue's max_attempts, so the worker's attempt ceiling and the
      # queue's cannot drift.
      env {
        name  = "DATASETS_OPERATION_MAX_ATTEMPTS"
        value = tostring(local.datasets_retry_max_attempts)
      }

      env {
        name  = "DATASETS_OPERATION_BACKLOG_MAX"
        value = tostring(local.datasets_operation_backlog_max)
      }
    }

    # Same PSC subnet and egress the apis service uses (network.tf) — the
    # worker opens the identical Cloud SQL IAM session as the same runtime
    # identity, so it needs the identical network path.
    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        network    = module.psc_network.network_id
        subnetwork = module.psc_network.subnetwork_id
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  # Every grant the container's own startup path needs, named explicitly:
  # unlike google_cloud_run_v2_job.coverage (coverage.tf), which already
  # depends_on its own prerequisite grants, this resource had no ordering
  # edge into any of them, so Terraform's DAG could create the revision
  # before the bucket/Cloud SQL/self-signBlob grants existed. A revision
  # started with a real (non-placeholder) image and a missing grant fails
  # its startup probe the same way a missing worker surface does.
  depends_on = [
    google_storage_bucket_iam_member.datasets_worker_working_creator,
    google_storage_bucket_iam_member.datasets_worker_working_viewer,
    google_storage_bucket_iam_member.datasets_worker_pinned_creator,
    google_storage_bucket_iam_member.datasets_worker_pinned_viewer,
    google_storage_bucket_iam_member.datasets_worker_coverage_viewer,
    google_project_iam_member.datasets_worker_cloudsql_client,
    google_project_iam_member.datasets_worker_cloudsql_instance_user,
    google_sql_user.datasets_worker_runtime,
    google_service_account_iam_member.datasets_worker_token_creator,
    google_cloud_run_v2_service_iam_member.graph_generation_dc_viewer_worker,
  ]
}

# No allUsers invoker. The only caller is the invoker identity below, which
# Cloud Tasks mints an OIDC token as.
resource "google_cloud_run_v2_service_iam_member" "datasets_worker_invoker" {
  project  = google_cloud_run_v2_service.datasets_worker.project
  location = google_cloud_run_v2_service.datasets_worker.location
  name     = google_cloud_run_v2_service.datasets_worker.name
  role     = "roles/run.invoker"
  member   = google_service_account.datasets_worker_invoker.member
}

resource "google_cloud_run_v2_service_iam_member" "datasets_worker_deployer_run_developer" {
  project  = google_cloud_run_v2_service.datasets_worker.project
  location = google_cloud_run_v2_service.datasets_worker.location
  name     = google_cloud_run_v2_service.datasets_worker.name
  role     = "roles/run.developer"
  member   = "serviceAccount:${data.google_service_account.apis_deployer.email}"
}

output "datasets_worker_service_name" {
  description = "Cloud Run service name of the async worker."
  value       = google_cloud_run_v2_service.datasets_worker.name
}

output "datasets_worker_service_url" {
  description = "URL of the async worker service. dfo-apis's DFO_WORKER_URL (main.tf) reads this; it answers only inside the project (INGRESS_TRAFFIC_INTERNAL_ONLY) and only to the invoker identity below."
  value       = google_cloud_run_v2_service.datasets_worker.uri
}

# ─────────────────────────────────────────────────────────────────────────────
# Invoker identity (Cloud Tasks OIDC)
# ─────────────────────────────────────────────────────────────────────────────

# Purely a bearer identity: Cloud Tasks mints an OIDC token as this account
# when it dispatches a task, and Cloud Run IAM verifies that token against
# the run.invoker grant above. It never runs as anything itself and holds no
# other grant, unlike the coverage job's or migration runner's identities.
resource "google_service_account" "datasets_worker_invoker" {
  project      = var.project_id
  account_id   = "${var.namespace}-worker-invoker"
  display_name = "Datasets async worker Cloud Tasks invoker"
}

# The apis runtime identity is the one enqueuing tasks (the mint door, over
# budget), so it needs to name this account as the task's OIDC service
# account. Scoped to this one service account resource, not the project —
# iam.serviceAccountUser at the project level would let the apis runtime
# identity impersonate every service account in the project, including its
# own deployer-facing grants.
resource "google_service_account_iam_member" "datasets_worker_invoker_act_as" {
  service_account_id = google_service_account.datasets_worker_invoker.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}

output "datasets_worker_invoker_service_account_email" {
  description = "Email of the Cloud Tasks OIDC invoker identity. dfo-apis's DFO_WORKER_INVOKER_SERVICE_ACCOUNT (main.tf) reads this when it creates a task, and the worker's app-level OIDC check verifies an incoming token's email against it."
  value       = google_service_account.datasets_worker_invoker.email
}

# ─────────────────────────────────────────────────────────────────────────────
# Cloud Tasks queue
# ─────────────────────────────────────────────────────────────────────────────

# dispatch_deadline is not a queue-level field on google_cloud_tasks_queue —
# it is set per task, by the app, when it creates each task
# (CreateTaskRequest.task.http_request.dispatch_deadline), at 1800s. That is
# also Cloud Tasks' own ceiling for an HTTP target's dispatch_deadline.
resource "google_cloud_tasks_queue" "datasets_worker" {
  name     = "${var.namespace}-datasets-worker"
  project  = var.project_id
  location = var.region

  rate_limits {
    # Bounds the worker's concurrent load on the shared mixer, and matches
    # the service's max_instance_count above.
    max_concurrent_dispatches = local.datasets_worker_dispatch_concurrency
    max_dispatches_per_second = 4
  }

  retry_config {
    # The worker's lease/state-machine handling (claim by conditional
    # UPDATE, 409 on a live lease, re-claim after claimed_at +
    # run_deadline_seconds) makes a retry safe; these bounds keep a
    # permanently-failing operation from retrying forever rather than
    # surfacing as a failed operation.
    #
    # Invariant with the worker's lease: min_backoff exceeds dfo-apis's
    # run_deadline_seconds (1,620 s, local.datasets_operation_run_deadline_seconds).
    # A worker that dies the instant it claims fails the delivery at or after
    # claimed_at, and the retry lands min_backoff later, so the first retry
    # always arrives after claimed_at + 1,620 s and re-claims. A shorter
    # min_backoff meets the live lease, gets a 409 and burns an attempt.
    # min_backoff is 1,680 s: the lease plus 60 s of slack for clock skew.
    # max_backoff equals min_backoff, which caps every doubling, so every
    # retry is spaced the same and meets an expired lease. max_doublings is
    # Cloud Tasks' default of 16: the provider sends no zero, so a 0 here
    # leaves the queue at 16 and shows as a change in every plan.
    #
    # Cloud Tasks stops only once max_attempts is reached and
    # max_retry_duration has passed, so a duration longer than the fastest
    # run of attempts adds attempts beyond max_attempts. max_retry_duration
    # is the fastest start of the last attempt, (max_attempts - 1) *
    # min_backoff = 3,360 s, which makes max_attempts the exact bound. The
    # slowest run, where every attempt lasts the 1,800 s dispatch_deadline,
    # takes 3 * 1,800 + 2 * 1,680 = 8,760 s.
    max_attempts       = local.datasets_retry_max_attempts
    max_retry_duration = "${(local.datasets_retry_max_attempts - 1) * local.datasets_retry_backoff_seconds}s"
    min_backoff        = "${local.datasets_retry_backoff_seconds}s"
    max_backoff        = "${local.datasets_retry_backoff_seconds}s"
    max_doublings      = 16
  }

  depends_on = [google_project_service.cloudtasks]
}

# The apis runtime identity enqueues tasks onto this one queue, never
# project-wide.
resource "google_cloud_tasks_queue_iam_member" "datasets_worker_queue_enqueuer" {
  project  = google_cloud_tasks_queue.datasets_worker.project
  location = google_cloud_tasks_queue.datasets_worker.location
  name     = google_cloud_tasks_queue.datasets_worker.name
  role     = "roles/cloudtasks.enqueuer"
  member   = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}

output "datasets_worker_queue_name" {
  description = "Full resource name of the Cloud Tasks queue. dfo-apis's DFO_TASKS_QUEUE (main.tf) reads this."
  value       = google_cloud_tasks_queue.datasets_worker.id
}
