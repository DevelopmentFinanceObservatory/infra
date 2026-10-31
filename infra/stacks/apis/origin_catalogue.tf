# The origin catalogue: a job that builds the table of every provenance
# (DFO, base Data Commons and the UN System Data Commons) with the variables
# and topics each one holds, and the Scheduler/bucket/alerting plumbing
# around it. The apis service and the datasets worker load the published
# artifact at startup. The job publishes each build under
# "format-<n>/versions/<build id>/" and moves "format-<n>/current.json" to
# point at it last. It shares variables.tf's Spanner connection, main.tf's
# google_project_service.cloudscheduler and alert notification channel, and
# has its own identities and bucket.

# ─────────────────────────────────────────────────────────────────────────────
# Bucket
# ─────────────────────────────────────────────────────────────────────────────

# A dedicated bucket: the Datasets working bucket expires objects after 30
# days, which would delete `current.json` in a quiet month, and GCS has no
# prefix-scoped IAM, so the catalogue job's write access stays to its own
# artifact.
resource "google_storage_bucket" "origin_catalogue" {
  name                        = "${var.namespace}-origin-catalogue-${var.project_id}"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true

  # No lifecycle_rule: the job prunes its own old builds and the pointer it
  # leaves in place names a build a bucket-level age rule could delete.
}

output "origin_catalogue_bucket_name" {
  description = "Name of the origin catalogue artifact bucket. The job publishes under \"format-<n>/versions/<build id>/\" plus a \"format-<n>/current.json\" pointer; dfo-apis's ORIGIN_CATALOGUE_URI reads gs://<this>/."
  value       = google_storage_bucket.origin_catalogue.name
}

# ─────────────────────────────────────────────────────────────────────────────
# Job identity and its BigQuery/Spanner/storage access
# ─────────────────────────────────────────────────────────────────────────────

# Its own identity, so the grants below reach the catalogue job alone.
resource "google_service_account" "origin_catalogue_job" {
  project      = var.project_id
  account_id   = "${var.namespace}-origin-catalogue-job"
  display_name = "Origin catalogue build job"
}

# The job reads DFO's provenances, variables and observation fingerprint with
# EXTERNAL_QUERY against Spanner, which runs as the caller. The connection
# carries no delegate identity, so the Spanner grants are as necessary as the
# two BigQuery ones (bigquery.jobUser at the project, which has no narrower
# scope, and bigquery.connectionUser on the connection). It holds no
# roles/bigquery.readSessionUser, because the job pages query results through
# jobs.getQueryResults, opens no BigQuery Storage read session, and its image
# does not install the storage client.
resource "google_project_iam_member" "origin_catalogue_job_bigquery_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.origin_catalogue_job.member
}

resource "google_bigquery_connection_iam_member" "origin_catalogue_job_connection_user" {
  project       = var.project_id
  location      = var.region
  connection_id = var.dc_spanner_connection_id
  role          = "roles/bigquery.connectionUser"
  member        = google_service_account.origin_catalogue_job.member
}

resource "google_spanner_database_iam_member" "origin_catalogue_job_spanner_reader" {
  instance = var.dc_spanner_instance_id
  database = var.dc_spanner_database_id
  role     = "roles/spanner.databaseReader"
  member   = google_service_account.origin_catalogue_job.member
}

resource "google_spanner_instance_iam_member" "origin_catalogue_job_spanner_instance_viewer" {
  instance = var.dc_spanner_instance_id
  role     = "roles/spanner.viewer"
  member   = google_service_account.origin_catalogue_job.member
}

# The job overwrites "current.json" on every publish, takes and releases a
# create-only "lease.json", and prunes old builds, so it needs create, get,
# list and delete: roles/storage.objectUser.
resource "google_storage_bucket_iam_member" "origin_catalogue_job_object_user" {
  bucket = google_storage_bucket.origin_catalogue.name
  role   = "roles/storage.objectUser"
  member = google_service_account.origin_catalogue_job.member
}

# Read-only for the serving identities, which load the artifact at startup.
resource "google_storage_bucket_iam_member" "origin_catalogue_apis_runtime_viewer" {
  bucket = google_storage_bucket.origin_catalogue.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}

resource "google_storage_bucket_iam_member" "origin_catalogue_datasets_worker_viewer" {
  bucket = google_storage_bucket.origin_catalogue.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.datasets_worker.member
}

resource "google_service_account_iam_member" "origin_catalogue_job_deployer_act_as" {
  service_account_id = google_service_account.origin_catalogue_job.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${data.google_service_account.apis_deployer.email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Job
# ─────────────────────────────────────────────────────────────────────────────

variable "origin_catalogue_bootstrap_image" {
  description = "Overrides the image the origin catalogue Job is created with. The deploy pipeline replaces it per execution; null (the default) bootstraps from local.live_apis_image, the tag the apis service is currently running."
  type        = string
  default     = null
}

resource "google_cloud_run_v2_job" "origin_catalogue" {
  name     = "${var.namespace}-origin-catalogue"
  location = var.region
  project  = var.project_id

  deletion_protection = var.stateless_deletion_protection

  template {
    template {
      service_account = google_service_account.origin_catalogue_job.email

      # No retry. The Scheduler polls every 15 minutes and the job's lease
      # keeps overlapping executions from both building, so a retry only
      # delays the poll that would have started the next attempt.
      max_retries = 0

      # Equal to _MAX_RUN_SECONDS in dfo-apis's origin_catalogue.job. A
      # lease lapses after that long because Cloud Run has killed the run
      # holding it by then, so the two values move together.
      timeout = "7200s"

      containers {
        image   = coalesce(var.origin_catalogue_bootstrap_image, local.live_apis_image)
        command = ["python"]
        args    = ["-m", "origin_catalogue.job"]

        # A full build against the dev graph peaks at about 560 MiB resident
        # over 11 minutes, so 2Gi leaves more than three times that for the
        # base variable table to grow. One CPU suffices because the run
        # waits on mixer round trips.
        resources {
          limits = {
            cpu    = "1"
            memory = "2Gi"
          }
        }

        env {
          name  = "ORIGIN_CATALOGUE_URI"
          value = "gs://${google_storage_bucket.origin_catalogue.name}/"
        }

        env {
          name  = "ORIGIN_CATALOGUE_BQ_CONNECTION"
          value = "${var.project_id}.${var.region}.${var.dc_spanner_connection_id}"
        }

        # Our mixer, which the job reads base provenances, variables and
        # topics through. The dev graph serves reads anonymously, so
        # DATASETS_GRAPH_TOKEN stays unset, as on the apis service.
        env {
          name  = "DATASETS_GRAPH_BASE_URL"
          value = var.datasets_graph_base_url
        }

        env {
          name  = "UN_GRAPH_BASE_URL"
          value = var.un_graph_base_url
        }
      }

      # The same private path the service and the migrate Job use; the UN
      # deployment and the mixer sit on public addresses, reached over the
      # default route.
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
    google_bigquery_connection_iam_member.origin_catalogue_job_connection_user,
    google_storage_bucket_iam_member.origin_catalogue_job_object_user,
  ]
}

resource "google_cloud_run_v2_job_iam_member" "origin_catalogue_deployer_run_developer" {
  project  = google_cloud_run_v2_job.origin_catalogue.project
  location = google_cloud_run_v2_job.origin_catalogue.location
  name     = google_cloud_run_v2_job.origin_catalogue.name
  role     = "roles/run.developer"
  member   = "serviceAccount:${data.google_service_account.apis_deployer.email}"
}

output "origin_catalogue_job_name" {
  description = "Name of the origin catalogue Job. The deploy workflow runs `gcloud run jobs update --image`, then `gcloud run jobs execute --wait`, then a verify execution against it before it deploys the datasets worker and the apis service."
  value       = google_cloud_run_v2_job.origin_catalogue.name
}

# ─────────────────────────────────────────────────────────────────────────────
# Scheduler
# ─────────────────────────────────────────────────────────────────────────────

resource "google_service_account" "origin_catalogue_scheduler" {
  project      = var.project_id
  account_id   = "${var.namespace}-origin-cat-scheduler"
  display_name = "Origin catalogue job Cloud Scheduler trigger"
}

resource "google_cloud_run_v2_job_iam_member" "origin_catalogue_scheduler_invoker" {
  project  = google_cloud_run_v2_job.origin_catalogue.project
  location = google_cloud_run_v2_job.origin_catalogue.location
  name     = google_cloud_run_v2_job.origin_catalogue.name
  role     = "roles/run.invoker"
  member   = google_service_account.origin_catalogue_scheduler.member
}

resource "google_cloud_scheduler_job" "origin_catalogue" {
  name      = "${var.namespace}-origin-catalogue-tick"
  project   = var.project_id
  region    = var.region
  schedule  = "*/15 * * * *"
  time_zone = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.origin_catalogue.name}:run"

    oauth_token {
      service_account_email = google_service_account.origin_catalogue_scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.cloudscheduler,
    google_cloud_run_v2_job_iam_member.origin_catalogue_scheduler_invoker,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Alerting: a stale publish, a failed execution, or no run completing
# ─────────────────────────────────────────────────────────────────────────────

# dfo-apis's origin_catalogue.job logs `origin_catalogue_publish_stale` when
# an identity has gone unpublished for more than one cycle, including while
# IngestionLock holds the job off, and when the published build is older
# than a week plus one run and one cycle. It logs `origin_catalogue_job_failed`
# or `origin_catalogue_job_refused` and exits 1 on a failure, which the
# failed-execution condition catches.
resource "google_logging_metric" "origin_catalogue_stale" {
  name    = "${var.namespace}-origin-catalogue-publish-stale"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="${google_cloud_run_v2_job.origin_catalogue.name}"
    resource.labels.location="${var.region}"
    jsonPayload.event="origin_catalogue_publish_stale"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# Every run that exits 0 logs `origin_catalogue_job_heartbeat` last, naming
# the published build and its age. A Scheduler that stops starting the job
# produces no stale line and no failed execution. Only the heartbeat's
# absence shows it.
resource "google_logging_metric" "origin_catalogue_heartbeat" {
  name    = "${var.namespace}-origin-catalogue-heartbeat"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="${google_cloud_run_v2_job.origin_catalogue.name}"
    resource.labels.location="${var.region}"
    jsonPayload.event="origin_catalogue_job_heartbeat"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# Waits out the log-based metrics' propagation to Cloud Monitoring before
# the alert policy names them; graph_release.tf explains the failure this avoids.
resource "time_sleep" "origin_catalogue_metric_propagation" {
  depends_on = [
    google_logging_metric.origin_catalogue_stale,
    google_logging_metric.origin_catalogue_heartbeat,
  ]
  create_duration = "120s"
}

resource "google_monitoring_alert_policy" "origin_catalogue_stale" {
  project      = var.project_id
  display_name = "Origin catalogue build failed or publish stale"
  combiner     = "OR"

  depends_on = [time_sleep.origin_catalogue_metric_propagation]

  # ALIGN_SUM, since Cloud Logging writes a zero sample in the interval
  # beside each non-zero one, which ALIGN_COUNT would count as a stale line.
  conditions {
    display_name = "origin_catalogue_publish_stale logged"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.origin_catalogue_stale.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "900s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  conditions {
    display_name = "origin catalogue Job execution failed"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${google_cloud_run_v2_job.origin_catalogue.name}\" AND resource.labels.location=\"${var.region}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result=\"failed\""
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

# Its own policy, so its incident closes on its own timer. The stale and
# failed-execution conditions above auto-close after an hour, which would
# close an absence incident while the heartbeat is missing. Each
# 15-minute execution is its own run, and one that finds the build lease
# held returns and heartbeats. 9000 seconds exceeds the 7200-second
# task timeout plus one cycle, so one hung or timed-out build cannot open
# the alert on its own.
resource "google_monitoring_alert_policy" "origin_catalogue_heartbeat" {
  project      = var.project_id
  display_name = "Origin catalogue job not running"
  combiner     = "OR"

  depends_on = [time_sleep.origin_catalogue_metric_propagation]

  conditions {
    display_name = "no origin_catalogue_job_heartbeat for 9000s"

    condition_absent {
      filter   = "resource.type=\"cloud_run_job\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.origin_catalogue_heartbeat.name}\""
      duration = "9000s"

      aggregations {
        alignment_period   = "900s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = local.alert_notification_channels

  alert_strategy {
    auto_close = "604800s"
  }
}
