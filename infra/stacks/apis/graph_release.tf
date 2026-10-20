# The graph release: a job that reads the Data Commons Spanner database and
# publishes an immutable release of the platform tables and the DFO parts
# derived from them, after a gate and (while shadowing) a diff against the
# coverage and origin catalogue artifacts. The apis service and the datasets
# worker load the published release. The job writes each release's parts and
# manifest create-only and moves one pointer last, the same publication order
# coverage.tf describes for the coverage index. It reuses that file's
# Spanner ids and google_project_service.cloudscheduler, follows
# origin_catalogue.tf's alerting conventions, and has its own identities and
# bucket.

variable "graph_release_serving" {
  description = "Whether the apis service and datasets worker load the graph release (GRAPH_RELEASE_URI). They refuse to start when no release is published, so set it true only once the builder has published in this environment."
  type        = bool
  default     = false
}

variable "graph_release_coverage" {
  description = "Whether the apis service, the datasets worker and the search catalogue job serve the code index and coverage from the graph release (GRAPH_RELEASE_COVERAGE=1) in place of the coverage artifact. Requires graph_release_serving. The release must already carry its serving views, which the builder publishes whenever it runs."
  type        = bool
  default     = false

  validation {
    condition     = !var.graph_release_coverage || var.graph_release_serving
    error_message = "graph_release_coverage reads the release that graph_release_serving mounts, so it requires graph_release_serving."
  }
}

variable "graph_release_origin" {
  description = "Whether the apis service, the datasets worker and the search catalogue job read the origin catalogue from the graph release (GRAPH_RELEASE_ORIGIN=1) in place of the origin catalogue artifact. Requires graph_release_coverage, since dfo-apis refuses GRAPH_RELEASE_ORIGIN without GRAPH_RELEASE_COVERAGE at startup."
  type        = bool
  default     = false

  validation {
    condition     = !var.graph_release_origin || var.graph_release_coverage
    error_message = "graph_release_origin reads the release that graph_release_coverage binds, so it requires graph_release_coverage."
  }
}

variable "graph_release_shadow" {
  description = "Whether the builder diffs each release against the coverage index and origin catalogue builds (GRAPH_RELEASE_SHADOW=1) before it publishes. False leaves the variable unset, so a release publishes without those builds."
  type        = bool
  default     = true
}

variable "graph_release_enabled" {
  description = "Whether the graph release builder runs. False (the default) creates the Scheduler trigger paused and the alert policies disabled, so the stack applies before the dfo-apis image that carries graph_release.job is deployed. Set true once that image is live."
  type        = bool
  default     = false
}

# ─────────────────────────────────────────────────────────────────────────────
# Bucket
# ─────────────────────────────────────────────────────────────────────────────

# A dedicated bucket, for the reasons coverage.tf gives for its own: the
# Datasets working bucket expires objects after 30 days, which would delete
# the pointer in a quiet month, and GCS has no prefix-scoped IAM. It is
# separate from the coverage and origin catalogue buckets, so the builder's
# write access reaches only its own releases.
resource "google_storage_bucket" "graph_release" {
  name                        = "${var.namespace}-graph-release-${var.project_id}"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true

  # No lifecycle_rule, for the reason coverage.tf gives: the job prunes
  # releases itself, and the pointer names a manifest a bucket-level age
  # rule could delete.
}

output "graph_release_bucket_name" {
  description = "Name of the graph release bucket. The job publishes parts and manifests and moves one pointer; dfo-apis's GRAPH_RELEASE_URI reads gs://<this>/."
  value       = google_storage_bucket.graph_release.name
}

# ─────────────────────────────────────────────────────────────────────────────
# Job identity and its Spanner, Cloud Run and storage access
# ─────────────────────────────────────────────────────────────────────────────

# Its own identity, so the grants below reach the builder alone.
resource "google_service_account" "graph_release_job" {
  project      = var.project_id
  account_id   = "${var.namespace}-graph-release-job"
  display_name = "Graph release build job"
}

# The job reads the Data Commons database directly with the Spanner client,
# which needs the database reader role. It reads through no BigQuery
# connection, so it holds no BigQuery role, no instance-level Spanner role
# and no Data Boost role.
resource "google_spanner_database_iam_member" "graph_release_job_spanner_reader" {
  instance = var.dc_spanner_instance_id
  database = var.dc_spanner_database_id
  role     = "roles/spanner.databaseReader"
  member   = google_service_account.graph_release_job.member
}

# The job reads the DC service's serving revision through the Cloud Run Admin
# API, as graph_generation_access.tf grants the serving identities, and
# stamps each release with it.
resource "google_cloud_run_v2_service_iam_member" "graph_release_job_dc_viewer" {
  project  = var.project_id
  location = var.region
  name     = var.datacommons_service_name
  role     = "roles/run.viewer"
  member   = google_service_account.graph_release_job.member
}

# The job creates parts and manifests, moves the pointer, takes and releases
# a create-only lease, and prunes old releases, so it needs create, get, list
# and delete: roles/storage.objectUser, as coverage.tf grants.
resource "google_storage_bucket_iam_member" "graph_release_job_object_user" {
  bucket = google_storage_bucket.graph_release.name
  role   = "roles/storage.objectUser"
  member = google_service_account.graph_release_job.member
}

# Read-only on the artifacts the shadow diff compares against.
resource "google_storage_bucket_iam_member" "graph_release_job_coverage_viewer" {
  bucket = google_storage_bucket.coverage.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.graph_release_job.member
}

resource "google_storage_bucket_iam_member" "graph_release_job_origin_catalogue_viewer" {
  bucket = google_storage_bucket.origin_catalogue.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.graph_release_job.member
}

# Read-only for the serving identities, which load the release.
resource "google_storage_bucket_iam_member" "graph_release_apis_runtime_viewer" {
  bucket = google_storage_bucket.graph_release.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}

resource "google_storage_bucket_iam_member" "graph_release_datasets_worker_viewer" {
  bucket = google_storage_bucket.graph_release.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.datasets_worker.member
}

# The search catalogue job loads the release it builds the catalogue from,
# once var.graph_release_coverage is true.
resource "google_storage_bucket_iam_member" "graph_release_search_catalogue_viewer" {
  count = var.graph_release_coverage ? 1 : 0

  bucket = google_storage_bucket.graph_release.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.search_catalogue_job.member
}

resource "google_service_account_iam_member" "graph_release_job_deployer_act_as" {
  service_account_id = google_service_account.graph_release_job.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${data.google_service_account.apis_deployer.email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Job
# ─────────────────────────────────────────────────────────────────────────────

variable "graph_release_bootstrap_image" {
  description = "Overrides the image the graph release Job is created with. The deploy pipeline replaces it per execution; null (the default) bootstraps from local.live_apis_image, as coverage_job_bootstrap_image does."
  type        = string
  default     = null
}

resource "google_cloud_run_v2_job" "graph_release" {
  name     = "${var.namespace}-graph-release"
  location = var.region
  project  = var.project_id

  deletion_protection = var.stateless_deletion_protection

  template {
    template {
      service_account = google_service_account.graph_release_job.email

      # No retry. The Scheduler polls every 2 minutes and the job's lease
      # keeps overlapping executions from both building, so a retry only
      # delays the poll that would have started the next attempt.
      max_retries = 0

      # Equal to the lease ttl in dfo-apis's graph_release.job. A lease
      # lapses after that long because Cloud Run has killed the run holding
      # it by then, and the job has no renewal, so the two values move
      # together.
      timeout = "1800s"

      containers {
        image   = coalesce(var.graph_release_bootstrap_image, local.live_apis_image)
        command = ["python"]
        args    = ["-m", "graph_release.job"]

        resources {
          limits = {
            cpu    = "2"
            memory = "8Gi"
          }
        }

        env {
          name  = "GRAPH_RELEASE_URI"
          value = "gs://${google_storage_bucket.graph_release.name}/"
        }

        env {
          name  = "GRAPH_RELEASE_SPANNER_PROJECT"
          value = var.project_id
        }

        env {
          name  = "GRAPH_RELEASE_SPANNER_INSTANCE"
          value = var.dc_spanner_instance_id
        }

        env {
          name  = "GRAPH_RELEASE_SPANNER_DATABASE"
          value = var.dc_spanner_database_id
        }

        env {
          name  = "DATACOMMONS_SERVICE_NAME"
          value = "projects/${var.project_id}/locations/${var.region}/services/${var.datacommons_service_name}"
        }

        # Our mixer and its SDMX API, which the gate reads. The dev graph
        # serves reads anonymously, so DATASETS_GRAPH_TOKEN stays unset, as on
        # the apis service.
        env {
          name  = "DATASETS_GRAPH_BASE_URL"
          value = var.datasets_graph_base_url
        }

        env {
          name  = "DATASETS_SDMX_BASE_URL"
          value = var.datasets_sdmx_base_url
        }

        # The shadow diff compares each release with the coverage and origin
        # catalogue builds named below. Turning it off lets a release publish
        # without them.
        dynamic "env" {
          for_each = var.graph_release_shadow ? [1] : []
          content {
            name  = "GRAPH_RELEASE_SHADOW"
            value = "1"
          }
        }

        env {
          name  = "COVERAGE_ARTIFACT_URI"
          value = "gs://${google_storage_bucket.coverage.name}/"
        }

        env {
          name  = "ORIGIN_CATALOGUE_URI"
          value = "gs://${google_storage_bucket.origin_catalogue.name}/"
        }

        # The builder starts one search catalogue execution after each
        # publish, through the Cloud Run Admin API. It does so whenever the
        # variable is set, whatever graph_release_coverage says: without the
        # flag the execution finds an unchanged build key and exits.
        env {
          name  = "SEARCH_CATALOGUE_JOB_NAME"
          value = "projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.search_catalogue.name}"
        }

        env {
          name  = "SPANNER_DISABLE_BUILTIN_METRICS"
          value = "true"
        }
      }

      # The same private path coverage.tf gives its Job; the mixer sits on a
      # public address, reached over the default route.
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
    google_spanner_database_iam_member.graph_release_job_spanner_reader,
    google_storage_bucket_iam_member.graph_release_job_object_user,
  ]
}

resource "google_cloud_run_v2_job_iam_member" "graph_release_deployer_run_developer" {
  project  = google_cloud_run_v2_job.graph_release.project
  location = google_cloud_run_v2_job.graph_release.location
  name     = google_cloud_run_v2_job.graph_release.name
  role     = "roles/run.developer"
  member   = "serviceAccount:${data.google_service_account.apis_deployer.email}"
}

# run.jobs.run against the search catalogue job alone, for the call the
# builder makes after each publish.
resource "google_cloud_run_v2_job_iam_member" "graph_release_job_catalogue_invoker" {
  project  = google_cloud_run_v2_job.search_catalogue.project
  location = google_cloud_run_v2_job.search_catalogue.location
  name     = google_cloud_run_v2_job.search_catalogue.name
  role     = "roles/run.invoker"
  member   = google_service_account.graph_release_job.member
}

output "graph_release_job_name" {
  description = "Name of the graph release Job. The deploy workflow runs `gcloud run jobs update --image` against it before it deploys the datasets worker and the apis service."
  value       = google_cloud_run_v2_job.graph_release.name
}

# ─────────────────────────────────────────────────────────────────────────────
# Scheduler
# ─────────────────────────────────────────────────────────────────────────────

resource "google_service_account" "graph_release_scheduler" {
  project      = var.project_id
  account_id   = "${var.namespace}-graph-rel-scheduler"
  display_name = "Graph release job Cloud Scheduler trigger"
}

resource "google_cloud_run_v2_job_iam_member" "graph_release_scheduler_invoker" {
  project  = google_cloud_run_v2_job.graph_release.project
  location = google_cloud_run_v2_job.graph_release.location
  name     = google_cloud_run_v2_job.graph_release.name
  role     = "roles/run.invoker"
  member   = google_service_account.graph_release_scheduler.member
}

resource "google_cloud_scheduler_job" "graph_release" {
  name      = "${var.namespace}-graph-release-tick"
  project   = var.project_id
  region    = var.region
  schedule  = "*/2 * * * *"
  time_zone = "Etc/UTC"
  paused    = !var.graph_release_enabled

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.graph_release.name}:run"

    oauth_token {
      service_account_email = google_service_account.graph_release_scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.cloudscheduler,
    google_cloud_run_v2_job_iam_member.graph_release_scheduler_invoker,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Alerting: a stale import, a failed gate, a dependency down, a catalogue trigger that failed, a failed execution, or no tick completing
# ─────────────────────────────────────────────────────────────────────────────

# dfo-apis's graph_release.job logs `graph_release_stale` while the newest
# import has waited over 30 minutes without a release, `graph_release_gate_failed`
# when the gate finds a deterministic fault and keeps the previous release
# serving, and `graph_release_unavailable` when a dependency (the mixer,
# SDMX, the bucket or the Admin API) could not answer. A gate finding and an
# unavailable dependency both exit 0, so these log metrics are their only
# alert. `graph_release_catalogue_trigger_failed` is logged at WARNING when
# the call that starts the search catalogue job after a publish fails. The
# job still reports the release as published and exits 0, so this metric is
# the only alert, and the catalogue stays on the previous release until the
# next publish or deploy starts the job. The job exits non-zero for an exception it does not classify, a task
# timeout or an out-of-memory kill, and the failed-execution condition below
# covers those. Ticks in the next 10 minutes with the same inputs skip without
# rebuilding, exit 0 and log the recorded `graph_release_unavailable` line again,
# marked as a backoff repeat. The first tick after that retries.
resource "google_logging_metric" "graph_release_stale" {
  name    = "${var.namespace}-graph-release-stale"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="${google_cloud_run_v2_job.graph_release.name}"
    resource.labels.location="${var.region}"
    jsonPayload.event="graph_release_stale"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "graph_release_gate_failed" {
  name    = "${var.namespace}-graph-release-gate-failed"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="${google_cloud_run_v2_job.graph_release.name}"
    resource.labels.location="${var.region}"
    jsonPayload.event="graph_release_gate_failed"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "graph_release_catalogue_trigger_failed" {
  name    = "${var.namespace}-graph-release-catalogue-trigger-failed"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="${google_cloud_run_v2_job.graph_release.name}"
    resource.labels.location="${var.region}"
    jsonPayload.event="graph_release_catalogue_trigger_failed"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "graph_release_unavailable" {
  name    = "${var.namespace}-graph-release-unavailable"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="${google_cloud_run_v2_job.graph_release.name}"
    resource.labels.location="${var.region}"
    jsonPayload.event="graph_release_unavailable"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# Every tick logs `graph_release_heartbeat`. A Scheduler that stops starting
# the job produces no stale line and no failed execution. Only the heartbeat's
# absence shows it. The metric counts every tick that exits by a path the job
# classifies: published, skipped, gate failed or dependency unavailable. It
# leaves out two outcomes. A tick that raises an exception it does not
# classify logs `error` and no stale, gate or unavailable line. A build killed
# by the task timeout or out of memory logs nothing and leaves its lease, and
# every tick the lease blocks logs `lease_held`. Counting either would keep
# the heartbeat present while no build completes. The absence alert below
# covers a Scheduler that stopped and a build killed on every run. An absence
# condition arms only after its series has existed, so a builder that has
# never logged a heartbeat is covered by the failed-execution condition on
# the stale policy, which needs no earlier sample.
resource "google_logging_metric" "graph_release_heartbeat" {
  name    = "${var.namespace}-graph-release-heartbeat"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="${google_cloud_run_v2_job.graph_release.name}"
    resource.labels.location="${var.region}"
    jsonPayload.event="graph_release_heartbeat"
    NOT jsonPayload.outcome="error"
    NOT jsonPayload.outcome="lease_held"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

variable "graph_release_notification_channels" {
  description = "Existing Cloud Monitoring notification channel resource names to notify for a stale or gate-failed graph release, an unavailable dependency, a failed catalogue trigger, a failed builder execution or a builder that stopped running."
  type        = list(string)
  default     = []
}

# Waits out the log-based metrics' propagation to Cloud Monitoring before
# the alert policies name them; coverage.tf explains the failure this avoids.
resource "time_sleep" "graph_release_metric_propagation" {
  depends_on = [
    google_logging_metric.graph_release_stale,
    google_logging_metric.graph_release_gate_failed,
    google_logging_metric.graph_release_unavailable,
    google_logging_metric.graph_release_catalogue_trigger_failed,
    google_logging_metric.graph_release_heartbeat,
  ]
  create_duration = "120s"
}

resource "google_monitoring_alert_policy" "graph_release_stale" {
  project      = var.project_id
  display_name = "Graph release stale, gate failed, dependency unavailable, catalogue trigger failed or execution failed"
  combiner     = "OR"
  enabled      = var.graph_release_enabled

  depends_on = [time_sleep.graph_release_metric_propagation]

  # ALIGN_SUM, since Cloud Logging writes a zero sample in the interval
  # beside each non-zero one, which ALIGN_COUNT would count as an event.
  conditions {
    display_name = "graph_release_stale logged"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.graph_release_stale.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "120s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  conditions {
    display_name = "graph_release_gate_failed logged"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.graph_release_gate_failed.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "120s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  # A dependency that is down for one tick is retried on the next, so this
  # condition fires only when it has answered nothing for 15 minutes. The ticks
  # that back off for 600 s after an unavailable result log the line again, and
  # so do the ticks that find the retry build holding the lease, so it recurs
  # every 2-minute tick for as long as the outage lasts.
  conditions {
    display_name = "graph_release_unavailable logged for 15 minutes"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.graph_release_unavailable.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "900s"

      aggregations {
        alignment_period   = "120s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  conditions {
    display_name = "graph_release_catalogue_trigger_failed logged"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.graph_release_catalogue_trigger_failed.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "120s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  # The job exits non-zero only for an unclassified exception, a task timeout
  # or an out-of-memory kill. It sits in this policy, not the heartbeat one,
  # because a failed execution is a discrete event and the 7-day auto-close
  # there would keep its incident open for a week after the job recovers. The
  # 120s period matches the 2-minute schedule.
  conditions {
    display_name = "graph release Job execution failed"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${google_cloud_run_v2_job.graph_release.name}\" AND resource.labels.location=\"${var.region}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result=\"failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "120s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = var.graph_release_notification_channels

  alert_strategy {
    auto_close = "3600s"
  }
}

# Its own policy, so its incident closes on its own timer. The conditions
# above auto-close after an hour, which would close an absence incident
# while the heartbeat is missing. 2100 seconds exceeds the 1800-second task
# timeout plus one 2-minute tick, so a healthy build, which logs its own
# heartbeat when it finishes, lands it inside the window. A build killed at the
# timeout logs none, and the `lease_held` ticks after it are not counted, so
# the alert opens once the window passes.
resource "google_monitoring_alert_policy" "graph_release_heartbeat" {
  project      = var.project_id
  display_name = "Graph release job not running"
  combiner     = "OR"
  enabled      = var.graph_release_enabled

  depends_on = [time_sleep.graph_release_metric_propagation]

  conditions {
    display_name = "no graph_release_heartbeat for 2100s"

    condition_absent {
      filter   = "resource.type=\"cloud_run_job\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.graph_release_heartbeat.name}\""
      duration = "2100s"

      aggregations {
        alignment_period   = "120s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = var.graph_release_notification_channels

  alert_strategy {
    auto_close = "604800s"
  }
}
