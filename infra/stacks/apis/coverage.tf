# The coverage index: a job that builds a Parquet artifact from Spanner after
# each data load, one row per (variable, facet_id, donor, recipient), and the
# Scheduler/bucket/alerting plumbing around it. Search and the mint door load
# it at startup and filter by role bindings, window and year in memory
# instead of reading the graph. The job publishes each build under
# "versions/<stamp>/" in the bucket below and moves "current.json" to point
# at it last; it compares a fingerprint of the source data against the
# published stamp and skips the build when they already agree.

# Every resource here except the bucket exists only while
# var.legacy_coverage_pipeline is true. The bucket stays either way, so
# turning the variable off deletes no data.

variable "legacy_coverage_pipeline" {
  description = "Whether the coverage job, its Scheduler tick, identities, grants and alerting exist, and whether the apis service, datasets worker and search catalogue job get COVERAGE_ARTIFACT_URI and read access to the coverage bucket. False needs a dfo-apis image that serves coverage from the graph release (graph_release_coverage) and a builder that no longer shadows (graph_release_shadow false). Prod can turn it off once it serves from the graph release. The bucket stays either way."
  type        = bool
  default     = true

  validation {
    condition     = var.legacy_coverage_pipeline || (var.graph_release_coverage && !var.graph_release_shadow)
    error_message = "legacy_coverage_pipeline false removes COVERAGE_ARTIFACT_URI, which the services read until graph_release_coverage is true and the builder's shadow diff reads while graph_release_shadow is true."
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Bucket
# ─────────────────────────────────────────────────────────────────────────────

# A dedicated bucket rather than a prefix in either existing one. The
# Datasets working bucket expires objects after 30 days (dcp stack), which
# would delete `current.json` during a quiet month and fail every surface's
# startup; the Data Commons `dc_artifacts` ingestion bucket has its IAM owned
# by the vendored upstream module, and GCS has no prefix-scoped IAM without
# per-object conditions, so granting on it would also hand the job write
# access to ingestion's own jsonld/temp objects.
resource "google_storage_bucket" "coverage" {
  name                        = "${var.namespace}-coverage-${var.project_id}"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true

  # Path-based versioning, not GCS object versioning: the job writes each
  # build under "versions/<stamp>/" and moves a single "current.json" object
  # at the bucket root to point at the live one (publication order in
  # dfo-apis's series_coverage.job).
  #
  # No lifecycle_rule here. The job prunes its own old versions (keeping the
  # current and previous stamp) after every successful publish and every
  # no-op run, so a bucket-level age rule would be redundant and strictly
  # worse: it cannot tell a quiet month with no new data load from genuine
  # staleness, and a rule scoped to the "versions/" prefix would leave
  # "current.json" alone while still deleting the version it points at out
  # from under it. roles/storage.objectUser below already grants
  # google_service_account.coverage_job create, get, list AND delete on this
  # bucket's objects, so the job's self-prune needs no additional grant.
}

output "coverage_bucket_name" {
  description = "Name of the coverage artifact bucket. The job publishes to \"versions/<stamp>/\" plus a root \"current.json\" pointer; dfo-apis's COVERAGE_ARTIFACT_URI reads gs://<this>/."
  value       = google_storage_bucket.coverage.name
}

# ─────────────────────────────────────────────────────────────────────────────
# Job identity and its BigQuery/Spanner/storage access
# ─────────────────────────────────────────────────────────────────────────────

# A dedicated identity, distinct from module.apis_service.runtime_service_account_email
# for the same reason datasets_access.tf keeps the migration runner separate:
# the job holds BigQuery job-execution and Spanner-connection-read access the
# public, unauthenticated serving identity has no reason to carry.
resource "google_service_account" "coverage_job" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  project      = var.project_id
  account_id   = "${var.namespace}-coverage-job"
  display_name = "Coverage index build job"
}

# roles/bigquery.jobUser has no dataset- or connection-scoped equivalent —
# running a BigQuery job (the EXTERNAL_QUERY against Spanner) is authorised
# at the project level or not at all, so this is the narrowest grant that
# lets the job submit its own queries. It does not by itself grant read
# access to any table or connection; connectionUser and readSessionUser
# below do that.
resource "google_project_iam_member" "coverage_job_bigquery_job_user" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.coverage_job[0].member
}

# roles/bigquery.connectionUser on the connection resource itself, not the
# project: this is what lets the job submit an EXTERNAL_QUERY through the
# connection at all. It is not what authorizes the query against Spanner --
# this connection carries no delegate identity of its own (`bq show
# --connection` reports no serviceAccountId), so a Spanner federated query
# through it runs as the caller. Google's own docs
# (docs.cloud.google.com/bigquery/docs/spanner-federated-queries) name both
# grants a non-FGAC caller needs: bigquery.connectionUser here, plus
# spanner.databaseReader on the database itself (below).
resource "google_bigquery_connection_iam_member" "coverage_job_connection_user" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  project       = var.project_id
  location      = var.region
  connection_id = var.dc_spanner_connection_id
  role          = "roles/bigquery.connectionUser"
  member        = google_service_account.coverage_job[0].member
}

# The second grant docs.cloud.google.com/bigquery/docs/spanner-federated-queries
# names for a non-FGAC EXTERNAL_QUERY caller (see coverage_job_connection_user
# above for the first): read access on the database itself, since the query
# runs as the job's own identity, not a connection delegate. Data Boost is
# off on this connection, so roles/spanner.databaseReader is the right role,
# not the *WithDataBoost variant. It carries exactly what a parallel read
# query needs -- spanner.databases.beginReadOnlyTransaction, .select,
# .partitionQuery, .partitionRead, .getDdl -- confirmed via `gcloud iam
# roles describe roles/spanner.databaseReader`, nothing broader (no write,
# no schema, no instance-level admin).
resource "google_spanner_database_iam_member" "coverage_job_spanner_reader" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  instance = var.dc_spanner_instance_id
  database = var.dc_spanner_database_id
  role     = "roles/spanner.databaseReader"
  member   = google_service_account.coverage_job[0].member
}

# The database-level grant above is not enough on its own: BigQuery's read
# against Spanner also checks spanner.instances.get on the instance, which a
# database-scoped binding does not grant. roles/spanner.viewer is the
# read-only predefined role that carries it.
resource "google_spanner_instance_iam_member" "coverage_job_spanner_instance_viewer" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  instance = var.dc_spanner_instance_id
  role     = "roles/spanner.viewer"
  member   = google_service_account.coverage_job[0].member
}

# The BigQuery Storage Read API session the outer aggregation query opens
# over the EXTERNAL_QUERY's root-partitioned result. Project-scoped, like
# jobUser above — the API has no finer grain.
resource "google_project_iam_member" "coverage_job_read_session_user" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  project = var.project_id
  role    = "roles/bigquery.readSessionUser"
  member  = google_service_account.coverage_job[0].member
}

# The job overwrites "current.json" on every successful publish, so it needs
# create, not just create-once: roles/storage.objectUser (create, get, list,
# delete), never objectAdmin, which would also grant bucket-level IAM
# changes this identity has no reason to make. The same delete permission
# also covers the job's own prune of old "versions/" prefixes (see the
# bucket resource above), so this grant needs no widening for that.
resource "google_storage_bucket_iam_member" "coverage_job_object_user" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  bucket = google_storage_bucket.coverage.name
  role   = "roles/storage.objectUser"
  member = google_service_account.coverage_job[0].member
}

# Read-only for the serving identity: it loads the artifact at startup and
# on the recheck interval, and never writes to this bucket.
resource "google_storage_bucket_iam_member" "coverage_apis_runtime_viewer" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  bucket = google_storage_bucket.coverage.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}

# actAs so the deployer can attach this identity to the Job below, the same
# grant datasets_access.tf makes for the migration runner.
resource "google_service_account_iam_member" "coverage_job_deployer_act_as" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  service_account_id = google_service_account.coverage_job[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${data.google_service_account.apis_deployer.email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Job
# ─────────────────────────────────────────────────────────────────────────────

# Bootstrap only, the same rationale datasets_migrate_job.tf records for its
# own bootstrap image: a real dfo-apis image rather than the module's
# gcr.io/cloudrun/hello placeholder, so an execution against a Job the
# deploy pipeline has not yet pointed at the image carrying `series_coverage.job`
# fails loudly (no such module) instead of exiting 0 having built nothing.
# The deploy pipeline moves this with `gcloud run jobs update --image`
# before each execution; lifecycle.ignore_changes below keeps that from
# reading as drift.
variable "coverage_job_bootstrap_image" {
  description = "Overrides the image the coverage Job is created with. The deploy pipeline replaces it per execution; null (the default) bootstraps from local.live_apis_image, the tag the apis service is currently running — always a real dfo-apis image already in Artifact Registry."
  type        = string
  default     = null
}

resource "google_cloud_run_v2_job" "coverage" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  name     = "${var.namespace}-coverage"
  location = var.region
  project  = var.project_id

  # The coverage job is being retired. The provider refuses to destroy a job
  # whose stored deletion_protection is true, so the job drops it while still
  # declared, and a later apply with legacy_coverage_pipeline false destroys it.
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.coverage_job[0].email

      # Idempotent by design (fingerprint no-op, IngestionLock check,
      # discard-on-mismatch at publish), unlike the migrate job's
      # forward-only schema change, so a transient failure is safe to
      # retry once rather than always waiting on an operator.
      max_retries = 1
      timeout     = "1800s"

      containers {
        image   = coalesce(var.coverage_job_bootstrap_image, local.live_apis_image)
        command = ["python"]
        args    = ["-m", "series_coverage.job"]

        # The full BigQuery result is materialised as Python rows before it
        # becomes an Arrow table, about 1.2 KiB per row at peak. 3.81M rows
        # (2026-10-01) exceed 4Gi; 8Gi holds about 7M. Cloud Run needs 2 CPU
        # above 4Gi. Keep this explicit until the builder streams result batches.
        resources {
          limits = {
            cpu    = "2"
            memory = "8Gi"
          }
        }

        env {
          name  = "COVERAGE_ARTIFACT_URI"
          value = "gs://${google_storage_bucket.coverage.name}/"
        }

        # project.location.connection_id, the literal form BigQuery's
        # EXTERNAL_QUERY takes, distinct from the connection_id shape the
        # IAM grant above uses.
        env {
          name  = "COVERAGE_BQ_CONNECTION"
          value = "${var.project_id}.${var.region}.${var.dc_spanner_connection_id}"
        }

        env {
          name  = "DATASETS_SDMX_BASE_URL"
          value = var.datasets_sdmx_base_url
        }
      }

      # Same private path the service and the migrate Job use, needed here
      # only for the Cloud SQL Admin API call the connector path would make
      # if the job ever opened a database session directly; today it talks
      # to BigQuery and GCS over the public API surface on the default
      # route, and this keeps the job on one egress shape with the rest of
      # the stack rather than carving an exception.
      vpc_access {
        network_interfaces {
          network    = module.psc_network.network_id
          subnetwork = module.psc_network.subnetwork_id
        }
        egress = "PRIVATE_RANGES_ONLY"
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [
    google_bigquery_connection_iam_member.coverage_job_connection_user,
    google_storage_bucket_iam_member.coverage_job_object_user,
  ]
}

# CI updates the image and executes with --wait, the same run.developer
# grant datasets_migrate_job.tf makes for the migrate Job.
resource "google_cloud_run_v2_job_iam_member" "coverage_deployer_run_developer" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  project  = google_cloud_run_v2_job.coverage[0].project
  location = google_cloud_run_v2_job.coverage[0].location
  name     = google_cloud_run_v2_job.coverage[0].name
  role     = "roles/run.developer"
  member   = "serviceAccount:${data.google_service_account.apis_deployer.email}"
}

output "coverage_job_name" {
  description = "Name of the coverage Job, null while legacy_coverage_pipeline is false. The deploy workflow runs `gcloud run jobs update --image` then `gcloud run jobs execute --wait` against it before deploying the apis service, the same order the migrate Job's own note describes."
  value       = one(google_cloud_run_v2_job.coverage[*].name)
}

# ─────────────────────────────────────────────────────────────────────────────
# Scheduler
# ─────────────────────────────────────────────────────────────────────────────

# A dedicated identity purely to authenticate the Scheduler->Cloud Run Admin
# API call; it never runs as anything and holds no other grant.
resource "google_service_account" "coverage_scheduler" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  project      = var.project_id
  account_id   = "${var.namespace}-coverage-scheduler"
  display_name = "Coverage job Cloud Scheduler trigger"
}

# run.jobs.run against this one Job, via roles/run.invoker scoped to the Job
# resource — never project-wide, and never able to reach any other Job or
# service.
resource "google_cloud_run_v2_job_iam_member" "coverage_scheduler_invoker" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  project  = google_cloud_run_v2_job.coverage[0].project
  location = google_cloud_run_v2_job.coverage[0].location
  name     = google_cloud_run_v2_job.coverage[0].name
  role     = "roles/run.invoker"
  member   = google_service_account.coverage_scheduler[0].member
}

# Triggers via the Cloud Run Admin API's execute call, not an HTTPS call to
# the job itself (Jobs have no invocable URL). oauth_token, not oidc_token:
# the target is a Google API (run.googleapis.com), which authenticates
# OAuth access tokens, unlike the worker's HTTPS target below.
resource "google_cloud_scheduler_job" "coverage" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  name      = "${var.namespace}-coverage-tick"
  project   = var.project_id
  region    = var.region
  schedule  = "*/15 * * * *"
  time_zone = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.coverage[0].name}:run"

    oauth_token {
      service_account_email = google_service_account.coverage_scheduler[0].email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.cloudscheduler,
    google_cloud_run_v2_job_iam_member.coverage_scheduler_invoker,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Alerting: failed executions or a published stamp behind the fingerprint
# ─────────────────────────────────────────────────────────────────────────────

# The job logs a structured line at the end of every run. This metric and
# alert assume the exact contract dfo-apis's series_coverage.job must emit:
# `jsonPayload.event == "coverage_publish_stale"` when, at the end of a run,
# the currently published stamp still does not match the fingerprint the job
# just computed and at least one prior cycle has already passed with that
# same mismatch — the job's own state to keep, since Terraform has no view
# into it.
resource "google_logging_metric" "coverage_stale" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  name    = "${var.namespace}-coverage-publish-stale"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="${google_cloud_run_v2_job.coverage[0].name}"
    resource.labels.location="${var.region}"
    jsonPayload.event="coverage_publish_stale"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# google_monitoring_alert_policy.coverage_stale's first condition filters on
# this metric's type, created in the same apply. The Terraform google
# provider's create call for google_logging_metric returns as soon as the
# API accepts the metric definition, but Cloud Monitoring's own descriptor
# for a brand-new log-based metric can take up to a few minutes to propagate
# to the alerting backend; creating the alert policy immediately afterward
# risks a 404 "Cannot find metric(s) that match type" that a plain
# depends_on can't close, since that only orders the two API calls, not the
# metric's propagation between them. condition_threshold has no
# disable_metric_validation escape hatch (that argument exists only on
# condition_prometheus_query_language in the current provider), so this
# waits out the propagation window explicitly instead.
resource "time_sleep" "coverage_stale_metric_propagation" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  depends_on      = [google_logging_metric.coverage_stale]
  create_duration = "120s"
}

resource "google_monitoring_alert_policy" "coverage_stale" {
  count = var.legacy_coverage_pipeline ? 1 : 0

  project      = var.project_id
  display_name = "Coverage build failed or publish behind fingerprint"
  combiner     = "OR"

  depends_on = [time_sleep.coverage_stale_metric_propagation]

  conditions {
    display_name = "coverage_publish_stale logged"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.coverage_stale[0].name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      # ALIGN_SUM, since Cloud Logging writes a zero sample in the interval
      # beside each non-zero one, which ALIGN_COUNT would count as a stale line.
      aggregations {
        alignment_period   = "900s" # the job's own 15-minute cycle
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  # This platform metric also catches failures before the application can
  # emit coverage_publish_stale: startup/import errors, OOM kills, and jobs
  # that fail before the fingerprint is read.
  conditions {
    display_name = "coverage Job execution failed"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${google_cloud_run_v2_job.coverage[0].name}\" AND resource.labels.location=\"${var.region}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result=\"failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "900s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = local.alert_notification_channels

  alert_strategy {
    auto_close = "3600s"
  }
}
