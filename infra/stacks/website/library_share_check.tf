# The Library share check: a Cloud Run Job running dfo-website's
# `node dist/check-library-shares.cjs` once a day. It lists the published rows
# of `library_artifact` and reads each one's share, slot cards and slot rows
# from dfo-apis as the Library page reads them. Each failed read logs one line
# with `event` set to `library_share_check_failed`, and the run exits 1 when
# any artifact fails or the run cannot run at all.
#
# It runs as the website runtime identity, because it reads `library_artifact`
# with the grants the service holds, and it calls dfo-apis with an ID token
# minted as that identity, which website_apis_invoker (main.tf) already
# grants. It exists in every tier: Library admins publish while
# var.library_enabled is false, and dfo-dev's alert proves the check before
# prod's Library opens.

locals {
  library_share_check_name = "${local.website_name}-library-share-check"
}

# Bootstrap only, for the reason website_migrate_bootstrap_image records.
# gcr.io/cloudrun/hello has no node binary, so a Job the deploy pipeline has
# not yet moved fails on the command and exits non-zero.
variable "website_library_share_check_bootstrap_image" {
  description = "Image the Library share check Job is created with. The deploy pipeline replaces it per release. This value only has to be an image that cannot run the command, so an unmoved Job fails on the command and exits non-zero."
  type        = string
  default     = "gcr.io/cloudrun/hello"
}

# ─────────────────────────────────────────────────────────────────────────────
# Job
# ─────────────────────────────────────────────────────────────────────────────

resource "google_cloud_run_v2_job" "website_library_share_check" {
  name     = local.library_share_check_name
  location = var.region
  project  = var.project_id

  deletion_protection = var.stateless_deletion_protection

  template {
    template {
      service_account = module.website_service.runtime_service_account_email

      # The check rereads a transiently failing artifact once, after 30
      # seconds, inside the run. A retry would repeat every read and log every
      # lasting failure a second time. Each dfo-apis read can take 35
      # seconds, four run at a time, and a transient failure is read again,
      # so 3600 seconds leaves room for a Library of a few hundred slots.
      max_retries = 0
      timeout     = "3600s"

      containers {
        image   = var.website_library_share_check_bootstrap_image
        command = ["node"]
        args    = ["dist/check-library-shares.cjs"]

        # The run holds every artifact's result until its summary line.
        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }

        # The service's connection settings (main.tf), as its runtime user.
        env {
          name  = "WEBSITE_DB_HOST"
          value = var.platform_dns_name
        }

        env {
          name  = "WEBSITE_DB_NAME"
          value = google_sql_database.website.name
        }

        env {
          name  = "WEBSITE_DB_USER"
          value = google_sql_user.website_runtime.name
        }

        env {
          name  = "WEBSITE_DB_INSTANCE_CONNECTION_NAME"
          value = var.platform_postgres_connection_name
        }

        # The apis service the website's proxies call. See var.search_api_base.
        env {
          name  = "SEARCH_API_BASE"
          value = var.search_api_base
        }
      }

      # The service's private path to Postgres. dfo-apis is reached over its
      # public run.app URL on the default route.
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
    google_project_iam_member.website_cloudsql_client,
    google_project_iam_member.website_cloudsql_login,
  ]
}

# The deploy workflow's `gcloud run jobs update --image`, and a manual
# `gcloud run jobs execute`. The actAs grant on the runtime identity comes
# from module.website_service's deployer_members.
resource "google_cloud_run_v2_job_iam_member" "website_library_share_check_deployer_run_developer" {
  project  = google_cloud_run_v2_job.website_library_share_check.project
  location = google_cloud_run_v2_job.website_library_share_check.location
  name     = google_cloud_run_v2_job.website_library_share_check.name
  role     = "roles/run.developer"
  member   = "serviceAccount:${data.google_service_account.website_deployer.email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Scheduler
# ─────────────────────────────────────────────────────────────────────────────

# A dedicated identity purely to authenticate the Scheduler->Cloud Run Admin
# API call. It runs as nothing and holds no other grant. The short form keeps
# the id within 30 characters: dfo-dev-website-stg-libchk-sch (30),
# dfo-prod-website-libchk-sch (27).
resource "google_service_account" "website_library_share_check_scheduler" {
  account_id   = "${var.namespace}-website${local.tier_suffix_short}-libchk-sch"
  display_name = "Website Library share check Job Cloud Scheduler trigger (${var.tier})"
}

# run.jobs.run on this one Job. The trigger passes no overrides, so
# roles/run.invoker is enough.
resource "google_cloud_run_v2_job_iam_member" "website_library_share_check_scheduler_invoker" {
  project  = google_cloud_run_v2_job.website_library_share_check.project
  location = google_cloud_run_v2_job.website_library_share_check.location
  name     = google_cloud_run_v2_job.website_library_share_check.name
  role     = "roles/run.invoker"
  member   = google_service_account.website_library_share_check_scheduler.member
}

# 06:00 UTC, so a failure opens an incident at the start of the European
# working day. The Cloud Run Admin API's run call, as event_export.tf uses.
resource "google_cloud_scheduler_job" "website_library_share_check" {
  name      = "${local.library_share_check_name}-tick"
  project   = var.project_id
  region    = var.region
  schedule  = "0 6 * * *"
  time_zone = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.website_library_share_check.name}:run"

    oauth_token {
      service_account_email = google_service_account.website_library_share_check_scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.apis,
    google_cloud_run_v2_job_iam_member.website_library_share_check_scheduler_invoker,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Alerting: a failed read, a failed execution, or no completed run
# ─────────────────────────────────────────────────────────────────────────────

# Every alert policy in the stack notifies this channel. Its absence leaves the
# policies in Cloud Monitoring with no one notified, as in dfo-dev.
data "google_monitoring_notification_channel" "alerts" {
  count = var.alert_notification_channel == null ? 0 : 1

  project      = var.project_id
  display_name = var.alert_notification_channel
}

locals {
  alert_notification_channels = data.google_monitoring_notification_channel.alerts[*].name
}

# One count per failed read: the share, a slot's card or a slot's rows, after
# the run's second read of a transient failure. A run that cannot reach the
# database or lacks a setting logs one line with class `check_failed`. The
# line goes to stdout or stderr as JSON, and Cloud Run parses both into
# jsonPayload. dfo-website's docs/development.md ("Library share check") keeps
# the event name fixed for this filter.
resource "google_logging_metric" "library_share_check_failed" {
  name    = "${local.website_name}-library-share-check-failed"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="${google_cloud_run_v2_job.website_library_share_check.name}"
    resource.labels.location="${var.region}"
    jsonPayload.event="library_share_check_failed"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# Every run that reaches its end logs `library_share_check_summary` last,
# whether or not an artifact failed. A Scheduler that stops starting the Job,
# or a run killed every day, logs no failure line, and only the summary's
# absence shows it. The name uses underscores so PromQL can name the metric
# as logging_googleapis_com:user_<name> without quoting.
resource "google_logging_metric" "library_share_check_summary" {
  name    = replace("${local.website_name}-library-share-check-summary", "-", "_")
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="${google_cloud_run_v2_job.website_library_share_check.name}"
    resource.labels.location="${var.region}"
    jsonPayload.event="library_share_check_summary"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# Waits out the log-based metrics' propagation to Cloud Monitoring before the
# alert policies name them. The apis stack's graph_release.tf explains the 404
# a plain depends_on leaves open.
resource "time_sleep" "library_share_check_metric_propagation" {
  depends_on = [
    google_logging_metric.library_share_check_failed,
    google_logging_metric.library_share_check_summary,
  ]
  # A new metric replaces the sleep, so the policies wait for it as they did
  # for the first ones. depends_on alone leaves an existing sleep in place.
  triggers = {
    metrics = join(",", [
      google_logging_metric.library_share_check_failed.name,
      google_logging_metric.library_share_check_summary.name,
    ])
  }
  create_duration = "120s"
}

# Two conditions, since each catches what the other can miss. The failure
# lines name the artifact, slot and class of every broken read. The failed
# execution count catches a run that dies before it logs: an import error, an
# OOM kill, the 3600-second timeout, or the bootstrap image an unmoved Job
# still runs. A run with failed reads exits 1, so both conditions open
# together then.
resource "google_monitoring_alert_policy" "library_share_check_failed" {
  project      = var.project_id
  display_name = "Library share check failed on ${local.website_name}"
  combiner     = "OR"

  depends_on = [time_sleep.library_share_check_metric_propagation]

  # ALIGN_SUM, since Cloud Logging writes a zero sample in the interval
  # beside each non-zero one, which ALIGN_COUNT would count as a failure.
  conditions {
    display_name = "library_share_check_failed logged"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.library_share_check_failed.name}\""
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
    display_name = "Library share check Job execution failed"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${google_cloud_run_v2_job.website_library_share_check.name}\" AND resource.labels.location=\"${var.region}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result=\"failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "900s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      A published Library artifact on ${local.website_name} did not read as its page reads it, or the daily check could not run. In Logs Explorer, filter on `resource.type="cloud_run_job" resource.labels.job_name="${google_cloud_run_v2_job.website_library_share_check.name}" jsonPayload.event="library_share_check_failed"`. Each line names the artifact's `slug`, its `share`, the `slot` (null for the share itself) and a `class`.

      `share_gone` means the share answers 404 and the page shows nothing. `frame_unavailable` means dfo-apis cannot draw a slot's frame. `no_rows` means a live slot answers with no rows. `refused` is any other refusal. `transient` failed twice, 30 seconds apart. `check_failed` means the run could not start its reads; its `code` names the missing setting or the database error.

      No failure line with a failed execution means the run died before it logged. Read the Job's last lines with `gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="${google_cloud_run_v2_job.website_library_share_check.name}"' --project=${var.project_id} --freshness=1d --limit=50`, and list its executions with `gcloud run jobs executions list --job=${google_cloud_run_v2_job.website_library_share_check.name} --region=${var.region} --project=${var.project_id}`. An execution of `gcr.io/cloudrun/hello` means the deploy has not yet moved the Job's image. Run the check again with `gcloud run jobs execute ${google_cloud_run_v2_job.website_library_share_check.name} --region=${var.region} --project=${var.project_id} --wait`.
    EOT
  }

  notification_channels = local.alert_notification_channels

  alert_strategy {
    auto_close = "3600s"
  }
}

# Its own policy, so its incident closes on its own timer, as the apis stack's
# graph_release_heartbeat does. 26 hours is the daily schedule plus two hours
# of run time and slack, the window the telemetry stack gives its daily GA4
# Job. The condition is PromQL, as there: it returns 1 when the window holds
# no summary line, and when the series is absent, so it also opens for a Job
# that has never completed, which a condition_absent misses. A policy created
# before the first run opens within minutes and closes after the first run
# that logs its summary.
resource "google_monitoring_alert_policy" "library_share_check_not_running" {
  project      = var.project_id
  display_name = "Library share check not running on ${local.website_name}"
  combiner     = "OR"

  depends_on = [time_sleep.library_share_check_metric_propagation]

  conditions {
    display_name = "no library_share_check_summary in 26 hours"

    condition_prometheus_query_language {
      query               = "(sum(sum_over_time(logging_googleapis_com:user_${google_logging_metric.library_share_check_summary.name}{monitored_resource=\"cloud_run_job\",job_name=\"${google_cloud_run_v2_job.website_library_share_check.name}\"}[26h])) < 1) or absent_over_time(logging_googleapis_com:user_${google_logging_metric.library_share_check_summary.name}{monitored_resource=\"cloud_run_job\",job_name=\"${google_cloud_run_v2_job.website_library_share_check.name}\"}[26h])"
      duration            = "0s"
      evaluation_interval = "300s"
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      No run of ${google_cloud_run_v2_job.website_library_share_check.name} has logged its `library_share_check_summary` line in 26 hours. Check that the Scheduler job ${google_cloud_scheduler_job.website_library_share_check.name} is enabled and its last attempt succeeded (`gcloud scheduler jobs describe ${google_cloud_scheduler_job.website_library_share_check.name} --location=${var.region} --project=${var.project_id}`), then read the Job's last lines with `gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="${google_cloud_run_v2_job.website_library_share_check.name}"' --project=${var.project_id} --freshness=2d --limit=50`.
    EOT
  }

  notification_channels = local.alert_notification_channels

  alert_strategy {
    auto_close = "604800s"
  }
}

output "library_share_check_job_name" {
  description = "Name of the Library share check Job. dfo-website's LIBRARY_SHARE_CHECK_JOB_WEBSITE in this environment's GitHub Environment. Run it with `gcloud run jobs execute <name> --wait`."
  value       = google_cloud_run_v2_job.website_library_share_check.name
}
