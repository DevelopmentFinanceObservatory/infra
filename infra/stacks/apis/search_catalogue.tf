# The search catalogue: a job that runs a set of example sentences through
# the search engine in-process, keeps the ones that answer with data, counts
# publishers, countries and aid, and publishes the result for
# GET /api/search/catalogue on the apis service. It publishes each build
# under "format-<n>/versions/<build id>/" and moves "format-<n>/current.json"
# to point at it last, as origin_catalogue.tf describes. Its build key is the
# origin catalogue build, the coverage index build (the graph release id
# while graph_release_coverage is true), the image's commit and the examples
# file, so it rebuilds after a publish of either artifact or a deploy, and
# exits in seconds otherwise. The graph release builder starts it after each
# publish. It shares coverage.tf's
# google_project_service.cloudscheduler and has its own identities and
# bucket.

# ─────────────────────────────────────────────────────────────────────────────
# Bucket
# ─────────────────────────────────────────────────────────────────────────────

# A dedicated bucket, for the reasons coverage.tf gives for its own, so the
# job's write access reaches only its own artifact.
resource "google_storage_bucket" "search_catalogue" {
  name                        = "${var.namespace}-search-catalogue-${var.project_id}"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true

  # No lifecycle_rule, for the reason coverage.tf gives: the job prunes its
  # own old builds and the pointer it leaves in place names a build a
  # bucket-level age rule could delete.
}

output "search_catalogue_bucket_name" {
  description = "Name of the search catalogue artifact bucket. The job publishes under \"format-<n>/versions/<build id>/\" plus a \"format-<n>/current.json\" pointer; dfo-apis's SEARCH_CATALOGUE_URI reads gs://<this>/."
  value       = google_storage_bucket.search_catalogue.name
}

# ─────────────────────────────────────────────────────────────────────────────
# Job identity and its storage and secret access
# ─────────────────────────────────────────────────────────────────────────────

# Its own identity, so the write grant below reaches the catalogue job alone.
# The engine reads the graph and Gemini over public APIs with no Google
# credential and resolves entities from the resolvekit cache baked into the
# image, so the job needs no BigQuery, Spanner or Cloud Run grant.
resource "google_service_account" "search_catalogue_job" {
  project      = var.project_id
  account_id   = "${var.namespace}-search-catalogue-job"
  display_name = "Search catalogue build job"
}

# The job overwrites "current.json" on every publish, takes and releases a
# create-only "lease.json", and prunes old builds, so it needs create, get,
# list and delete: roles/storage.objectUser, as coverage.tf grants.
resource "google_storage_bucket_iam_member" "search_catalogue_job_object_user" {
  bucket = google_storage_bucket.search_catalogue.name
  role   = "roles/storage.objectUser"
  member = google_service_account.search_catalogue_job.member
}

# The two artifacts the build key and the engine read: the origin catalogue
# build the engine binds and the coverage index it filters by.
resource "google_storage_bucket_iam_member" "search_catalogue_job_origin_catalogue_viewer" {
  bucket = google_storage_bucket.origin_catalogue.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.search_catalogue_job.member
}

resource "google_storage_bucket_iam_member" "search_catalogue_job_coverage_viewer" {
  bucket = google_storage_bucket.coverage.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.search_catalogue_job.member
}

# The engine's Gemini key, the secret main.tf mounts on the apis service,
# scoped to that one secret as the module scopes the service's own grant.
resource "google_secret_manager_secret_iam_member" "search_catalogue_job_gemini_accessor" {
  project   = data.google_secret_manager_secret.gemini.project
  secret_id = data.google_secret_manager_secret.gemini.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.search_catalogue_job.member
}

# Read-only for the serving identity, which serves the published build.
resource "google_storage_bucket_iam_member" "search_catalogue_apis_runtime_viewer" {
  bucket = google_storage_bucket.search_catalogue.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}

resource "google_service_account_iam_member" "search_catalogue_job_deployer_act_as" {
  service_account_id = google_service_account.search_catalogue_job.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${data.google_service_account.apis_deployer.email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Job
# ─────────────────────────────────────────────────────────────────────────────

variable "search_catalogue_bootstrap_image" {
  description = "Overrides the image the search catalogue Job is created with. The deploy pipeline replaces it per execution; null (the default) bootstraps from local.live_apis_image, as coverage_job_bootstrap_image does."
  type        = string
  default     = null
}

resource "google_cloud_run_v2_job" "search_catalogue" {
  name     = "${var.namespace}-search-catalogue"
  location = var.region
  project  = var.project_id

  deletion_protection = var.stateless_deletion_protection

  template {
    template {
      service_account = google_service_account.search_catalogue_job.email

      # No retry. The Scheduler polls every 15 minutes and the job's lease
      # keeps overlapping executions from both building, so a retry only
      # delays the poll that would have started the next attempt.
      max_retries = 0

      # Equal to _MAX_RUN_SECONDS in dfo-apis's search.catalogue.job. A lease
      # lapses after that long because Cloud Run has killed the run holding
      # it by then, so the two values move together. A build takes about
      # 90 seconds.
      timeout = "1800s"

      containers {
        image   = coalesce(var.search_catalogue_bootstrap_image, local.live_apis_image)
        command = ["python"]
        args    = ["-m", "search.catalogue.job"]

        # A build peaks near 1.2 GB resident. It loads the coverage index and
        # the origin catalogue the apis service holds, so the limits match
        # the service's and grow with the same data. One CPU suffices because
        # the run waits on Gemini and the graph.
        resources {
          limits = {
            cpu    = "1"
            memory = "4Gi"
          }
        }

        env {
          name  = "SEARCH_CATALOGUE_URI"
          value = "gs://${google_storage_bucket.search_catalogue.name}/"
        }

        env {
          name  = "ORIGIN_CATALOGUE_URI"
          value = "gs://${google_storage_bucket.origin_catalogue.name}/"
        }

        # The job refuses to start without this, also while
        # graph_release_coverage has it read the release instead.
        env {
          name  = "COVERAGE_ARTIFACT_URI"
          value = "gs://${google_storage_bucket.coverage.name}/"
        }

        # The release graph_release.tf's builder publishes: the job keys its
        # build on the release id and reads the code index and coverage from
        # the release in place of the coverage artifact.
        dynamic "env" {
          for_each = var.graph_release_coverage ? [1] : []
          content {
            name  = "GRAPH_RELEASE_URI"
            value = "gs://${google_storage_bucket.graph_release.name}/"
          }
        }

        dynamic "env" {
          for_each = var.graph_release_coverage ? [1] : []
          content {
            name  = "GRAPH_RELEASE_COVERAGE"
            value = "1"
          }
        }

        # The engine settings main.tf gives the apis service, so a build
        # checks each example against the engine users' requests reach.
        # SEARCH_GRAPH_TOKEN stays unset, as README.md explains for the
        # service. The job builds its graph client with an unknown
        # generation, so it takes no DFO_GRAPH_GENERATION_SERVICE.
        env {
          name  = "SEARCH_GRAPH_BASE"
          value = var.search_graph_base
        }

        env {
          name  = "SEARCH_ENGINE_MODEL"
          value = var.search_engine_model
        }

        env {
          name  = "UN_GRAPH_BASE_URL"
          value = var.un_graph_base_url
        }

        env {
          name = "GEMINI_API_KEY"
          value_source {
            secret_key_ref {
              secret  = data.google_secret_manager_secret.gemini.secret_id
              version = "latest"
            }
          }
        }
      }

      # The same private path coverage.tf gives its Job; the graph, Gemini
      # and GCS sit on public addresses, reached over the default route.
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
    google_secret_manager_secret_iam_member.search_catalogue_job_gemini_accessor,
    google_storage_bucket_iam_member.search_catalogue_job_object_user,
    google_storage_bucket_iam_member.search_catalogue_job_origin_catalogue_viewer,
    google_storage_bucket_iam_member.search_catalogue_job_coverage_viewer,
  ]
}

resource "google_cloud_run_v2_job_iam_member" "search_catalogue_deployer_run_developer" {
  project  = google_cloud_run_v2_job.search_catalogue.project
  location = google_cloud_run_v2_job.search_catalogue.location
  name     = google_cloud_run_v2_job.search_catalogue.name
  role     = "roles/run.developer"
  member   = "serviceAccount:${data.google_service_account.apis_deployer.email}"
}

output "search_catalogue_job_name" {
  description = "Name of the search catalogue Job. The deploy workflow runs `gcloud run jobs update --image` against it with each new dfo-apis image."
  value       = google_cloud_run_v2_job.search_catalogue.name
}

# ─────────────────────────────────────────────────────────────────────────────
# Scheduler
# ─────────────────────────────────────────────────────────────────────────────

resource "google_service_account" "search_catalogue_scheduler" {
  project      = var.project_id
  account_id   = "${var.namespace}-search-cat-scheduler"
  display_name = "Search catalogue job Cloud Scheduler trigger"
}

resource "google_cloud_run_v2_job_iam_member" "search_catalogue_scheduler_invoker" {
  project  = google_cloud_run_v2_job.search_catalogue.project
  location = google_cloud_run_v2_job.search_catalogue.location
  name     = google_cloud_run_v2_job.search_catalogue.name
  role     = "roles/run.invoker"
  member   = google_service_account.search_catalogue_scheduler.member
}

resource "google_cloud_scheduler_job" "search_catalogue" {
  name      = "${var.namespace}-search-catalogue-tick"
  project   = var.project_id
  region    = var.region
  schedule  = "*/15 * * * *"
  time_zone = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.search_catalogue.name}:run"

    oauth_token {
      service_account_email = google_service_account.search_catalogue_scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.cloudscheduler,
    google_cloud_run_v2_job_iam_member.search_catalogue_scheduler_invoker,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Alerting: a failed execution, a dropped example, or no run completing
# ─────────────────────────────────────────────────────────────────────────────

# dfo-apis's search.catalogue.job logs `search_catalogue_line_dropped` at
# WARNING for each example that has no data at a place it should or that the
# engine fails to answer. The run still publishes when at least five lines
# pass, so the drop exits 0 and only this metric shows it.
resource "google_logging_metric" "search_catalogue_line_dropped" {
  name    = "${var.namespace}-search-catalogue-line-dropped"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="${google_cloud_run_v2_job.search_catalogue.name}"
    resource.labels.location="${var.region}"
    jsonPayload.event="search_catalogue_line_dropped"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# Every run that exits 0 logs `search_catalogue_job_heartbeat` last, naming
# the published build and its age. A Scheduler that stops starting the job
# produces no dropped line and no failed execution. Only the heartbeat's
# absence shows it.
resource "google_logging_metric" "search_catalogue_heartbeat" {
  name    = "${var.namespace}-search-catalogue-heartbeat"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="${google_cloud_run_v2_job.search_catalogue.name}"
    resource.labels.location="${var.region}"
    jsonPayload.event="search_catalogue_job_heartbeat"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

variable "search_catalogue_notification_channels" {
  description = "Existing Cloud Monitoring notification channel resource names to notify for search catalogue build failures, dropped example lines or a job that stopped running."
  type        = list(string)
  default     = []
}

# Waits out the log-based metrics' propagation to Cloud Monitoring before
# the alert policies name them; coverage.tf explains the failure this avoids.
resource "time_sleep" "search_catalogue_metric_propagation" {
  depends_on = [
    google_logging_metric.search_catalogue_line_dropped,
    google_logging_metric.search_catalogue_heartbeat,
  ]
  create_duration = "120s"
}

# The job logs `search_catalogue_job_failed` or `search_catalogue_job_refused`
# at ERROR and exits 1, so Cloud Run's failed-execution count catches both,
# along with the failures that never reach the log line: an import error,
# an uncaught exception, an OOM kill or a timeout. The logged event names
# which one it was.
resource "google_monitoring_alert_policy" "search_catalogue_failed" {
  project      = var.project_id
  display_name = "Search catalogue build failed or refused"
  combiner     = "OR"

  conditions {
    display_name = "search catalogue Job execution failed"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${google_cloud_run_v2_job.search_catalogue.name}\" AND resource.labels.location=\"${var.region}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result=\"failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "900s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = var.search_catalogue_notification_channels

  alert_strategy {
    auto_close = "3600s"
  }
}

resource "google_monitoring_alert_policy" "search_catalogue_line_dropped" {
  project      = var.project_id
  display_name = "Search catalogue dropped an example"
  combiner     = "OR"

  depends_on = [time_sleep.search_catalogue_metric_propagation]

  # ALIGN_SUM, since Cloud Logging writes a zero sample in the interval
  # beside each non-zero one, which ALIGN_COUNT would count as a dropped line.
  conditions {
    display_name = "search_catalogue_line_dropped logged"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.search_catalogue_line_dropped.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "900s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = var.search_catalogue_notification_channels

  alert_strategy {
    auto_close = "3600s"
  }
}

# Its own policy, so its incident closes on its own timer, as
# origin_catalogue.tf explains. A run that finds the build lease held
# returns and heartbeats, so only a stopped Scheduler or every run failing
# leaves the heartbeat missing. 3600 seconds exceeds the 1800-second task
# timeout plus one cycle, so one hung or timed-out build cannot open the
# alert on its own.
resource "google_monitoring_alert_policy" "search_catalogue_heartbeat" {
  project      = var.project_id
  display_name = "Search catalogue job not running"
  combiner     = "OR"

  depends_on = [time_sleep.search_catalogue_metric_propagation]

  conditions {
    display_name = "no search_catalogue_job_heartbeat for 3600s"

    condition_absent {
      filter   = "resource.type=\"cloud_run_job\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.search_catalogue_heartbeat.name}\""
      duration = "3600s"

      aggregations {
        alignment_period   = "900s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = var.search_catalogue_notification_channels

  alert_strategy {
    auto_close = "604800s"
  }
}
