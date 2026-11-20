# The analytics repository's four scheduled Cloud Run Jobs, their Cloud
# Scheduler triggers and their alerts. All four run the one image the
# repository's Deploy workflow pushes to the analytics Artifact Registry
# repository (analytics.tf), and each Job's args pick the command, since the
# image has no entrypoint:
#
#   dfo-prod-analytics-dbt        dbt build --target prod, hourly at minute 25
#   dfo-prod-analytics-edge       python -m dfo_analytics.extract.edge, hourly at minute 5
#   dfo-prod-analytics-grade      python -m dfo_analytics.grade, daily at 04:30 UTC
#   dfo-prod-analytics-freshness  dbt source freshness --target prod, hourly at minute 50
#
# var.analytics_jobs_enabled creates everything in this file, and the
# freshness Job also waits for var.analytics_dbt_schedule_enabled. The
# datasets the Jobs write, their accounts and those accounts' dataset grants
# live in analytics.tf and exist whatever the flag says. README "Analytics jobs" gives
# the order to switch it on.

variable "analytics_jobs_enabled" {
  description = "Creates the analytics Jobs, their Scheduler triggers and alerts, and the grants only a running Job needs (the edge logs bucket, the secrets, the deployer's). Needs analytics_jobs_image."
  type        = bool
  default     = false
}

# The image a Job is created with. After that the analytics repository's
# deploy moves each Job to a new image, and lifecycle.ignore_changes keeps
# that from reading as drift, so a change here reaches only a Job being
# created.
variable "analytics_jobs_image" {
  description = "Image the analytics Jobs are created with, a sha-tagged image of the analytics Artifact Registry repository, such as europe-west1-docker.pkg.dev/prod-fin-observatory/analytics/dfo-analytics:<sha>. Required when analytics_jobs_enabled is true."
  type        = string
  default     = null

  validation {
    condition     = !var.analytics_jobs_enabled || var.analytics_jobs_image != null
    error_message = "analytics_jobs_enabled needs analytics_jobs_image, an image the analytics Deploy workflow pushed."
  }
}

# The dbt Job's hourly trigger, apart from the flag because the logs_daily
# cutover runs as one-off executions of the dbt Job before any scheduled build
# (README "Analytics jobs"). A scheduled build before the cutover's first step
# creates the six log-fed tables, and the archive copy then refuses to run.
# The same switch disables the logs_daily scheduled query (logs_daily.tf) and
# drops its absence alert (alerts.tf), since the dbt build replaces it, moves
# the dfo_reporting views over its tables to the analytics tables
# (reporting_views.tf), and creates the freshness Job, which checks the
# sources the scheduled build reads and so runs only beside it.
variable "analytics_dbt_schedule_enabled" {
  description = "Creates the dbt Job's hourly trigger and its alert and the source freshness Job, disables the logs_daily scheduled query the build replaces, and points the dfo_reporting views over the logs_daily tables at the analytics tables. Needs analytics_jobs_enabled. Switch it on once the logs_daily cutover has run and the views' parity check is clean."
  type        = bool
  default     = false

  validation {
    condition     = !var.analytics_dbt_schedule_enabled || var.analytics_jobs_enabled
    error_message = "analytics_dbt_schedule_enabled needs analytics_jobs_enabled."
  }
}

locals {
  analytics_jobs_count = var.analytics_jobs_enabled ? 1 : 0

  # Written by the edge-logs Logpush job into the bucket this stack's
  # edge_logs.tf creates, named here because that file lands on its own
  # branch. The bucket must exist before the flag is switched on.
  analytics_edge_logs_bucket = "${var.namespace}-edge-logs-${var.project_id}"

  # Copied from the ai stack's langfuse_base_url and
  # langfuse_tracing_environment (infra/stacks/ai/main.tf). The grader reads
  # the deployed traces langfuse_export holds for that environment and posts
  # its scores to the same Langfuse project.
  analytics_langfuse_base_url    = "https://cloud.langfuse.com"
  analytics_langfuse_environment = "${var.namespace}-ai"

  # The grader's lease lapses after this many minutes, and its README asks for
  # a task timeout of at most that, so the Job's timeout derives from it.
  analytics_grade_run_timeout_minutes = 60

  # Every Job has max_retries = 0, so a failed run is one failed execution and
  # the next scheduled run is the retry. Each Job's timeout keeps one execution
  # from overlapping the next trigger.
  analytics_jobs = {
    dbt = {
      account = google_service_account.analytics["runner"]
      args    = ["dbt", "build", "--target", "prod"]
      # dbt's own per-query timeout is 1800 s (the prod target in the
      # analytics repository's dbt/profiles.yml).
      timeout  = "2700s"
      memory   = "1Gi"
      schedule = "25 * * * *"
      env      = {}
      secrets  = {}
    }
    edge = {
      account = google_service_account.analytics_job["edge"]
      args    = ["python", "-m", "dfo_analytics.extract.edge"]
      timeout = "2700s"
      # An object at the extract's 256 MiB decompressed cap peaks near 1.3 GiB.
      memory = "2Gi"
      # Before dbt's minute 25, so the hourly build reads this hour's load.
      schedule = "5 * * * *"
      env = {
        EDGE_LOGS_BUCKET    = local.analytics_edge_logs_bucket
        EXPORT_BQ_PROJECT   = var.project_id
        EDGE_EXPORT_DATASET = google_bigquery_dataset.analytics_job["edge_export"].dataset_id
      }
      secrets = {
        CALLER_HMAC_KEY = "${var.namespace}-caller-hmac-key"
      }
    }
    grade = {
      account  = google_service_account.analytics_job["grader"]
      args     = ["python", "-m", "dfo_analytics.grade"]
      timeout  = "${local.analytics_grade_run_timeout_minutes * 60}s"
      memory   = "1Gi"
      schedule = "30 4 * * *"
      env = {
        GRADE_BQ_PROJECT            = var.project_id
        GRADE_SOURCE_DATASET        = "langfuse_export"
        GRADE_DATASET               = google_bigquery_dataset.analytics_job["studio_grades"].dataset_id
        GRADE_RUN_TIMEOUT_MINUTES   = tostring(local.analytics_grade_run_timeout_minutes)
        LANGFUSE_BASE_URL           = local.analytics_langfuse_base_url
        LANGFUSE_EXPORT_ENVIRONMENT = local.analytics_langfuse_environment
      }
      secrets = {
        LANGFUSE_PUBLIC_KEY = "${var.namespace}-langfuse-public-key"
        LANGFUSE_SECRET_KEY = "${var.namespace}-langfuse-secret-key"
        GOOGLE_API_KEY      = google_secret_manager_secret.analytics_grader_gemini.secret_id
      }
    }
    # Fails when a source's newest row is older than the error threshold its
    # dbt/models/sources.yml entry sets in the analytics repository. Runs as
    # the dbt account, which reads every source.
    freshness = {
      account  = google_service_account.analytics["runner"]
      args     = ["dbt", "source", "freshness", "--target", "prod", "--project-dir", "dbt", "--profiles-dir", "dbt"]
      timeout  = "900s"
      memory   = "1Gi"
      schedule = "50 * * * *"
      env      = {}
      secrets  = {}
    }
  }

  analytics_jobs_created = {
    for name, job in local.analytics_jobs : name => job
    if var.analytics_jobs_enabled && (name != "freshness" || var.analytics_dbt_schedule_enabled)
  }

  # One accessor grant per Job and secret it mounts.
  analytics_job_secret_grants = merge([
    for name, job in local.analytics_jobs_created : {
      for env_name, secret in job.secrets : "${name} ${env_name}" => { job = name, secret = secret }
    }
  ]...)

  # The dbt trigger waits for analytics_dbt_schedule_enabled.
  analytics_job_triggers = { for name, job in local.analytics_jobs_created : name => job if name != "dbt" || var.analytics_dbt_schedule_enabled }
}

# Both APIs are on in prod already (the apis and ai stacks use them). Declaring
# them here keeps this stack's applies independent of those stacks, and
# disable_on_destroy = false leaves them on for the other owners.
resource "google_project_service" "analytics_jobs" {
  for_each = var.analytics_jobs_enabled ? toset(["run.googleapis.com", "cloudscheduler.googleapis.com"]) : toset([])

  service            = each.key
  disable_on_destroy = false
}

# ─────────────────────────────────────────────────────────────────────────────
# What only a running Job needs
# ─────────────────────────────────────────────────────────────────────────────

# objectViewer lists and reads the objects. The extract never reads the
# bucket's own metadata.
resource "google_storage_bucket_iam_member" "analytics_edge_logs_reader" {
  count = local.analytics_jobs_count

  bucket = local.analytics_edge_logs_bucket
  role   = "roles/storage.objectViewer"
  member = google_service_account.analytics_job["edge"].member
}

# The caller HMAC key is owned by the apis stack (caller_hmac_key.tf) and the
# Langfuse keys are made by hand and read by the ai stack, so each grant is on
# that secret alone. The edge extract mounts the same caller key as the
# website and dfo-apis, so one client carries one caller in all three.
resource "google_secret_manager_secret_iam_member" "analytics_job_secret_accessor" {
  for_each = local.analytics_job_secret_grants

  project   = var.project_id
  secret_id = each.value.secret
  role      = "roles/secretmanager.secretAccessor"
  member    = local.analytics_jobs_created[each.value.job].account.member
}

# ─────────────────────────────────────────────────────────────────────────────
# Jobs
# ─────────────────────────────────────────────────────────────────────────────

resource "google_cloud_run_v2_job" "analytics" {
  for_each = local.analytics_jobs_created

  name     = "${var.namespace}-analytics-${each.key}"
  location = var.region
  project  = var.project_id

  # The Jobs hold no state, so switching the flag off may delete them.
  deletion_protection = false

  template {
    template {
      service_account = each.value.account.email
      max_retries     = 0
      timeout         = each.value.timeout

      containers {
        image = var.analytics_jobs_image
        args  = each.value.args

        resources {
          limits = {
            cpu    = "1"
            memory = each.value.memory
          }
        }

        dynamic "env" {
          for_each = each.value.env
          content {
            name  = env.key
            value = env.value
          }
        }

        # Read at `latest` when an execution starts, as the website mounts
        # the caller key.
        dynamic "env" {
          for_each = each.value.secrets
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = env.value
                version = "latest"
              }
            }
          }
        }
      }

      # No vpc_access. The Jobs reach BigQuery, Cloud Storage, Langfuse Cloud
      # and the Gemini API over the public internet.
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
    google_project_service.analytics_jobs,
    google_project_iam_member.analytics_job_user,
    google_project_iam_member.analytics_job_job_user,
    google_bigquery_dataset_access.analytics_writer,
    google_bigquery_dataset_access.analytics_job_writer,
    google_secret_manager_secret_iam_member.analytics_job_secret_accessor,
  ]
}

output "analytics_job_names" {
  description = "Names of the analytics Jobs by command (dbt, edge, grade), empty while analytics_jobs_enabled is false."
  value       = { for name, job in google_cloud_run_v2_job.analytics : name => job.name }
}

# The analytics deploy moves each Job to the new image with
# `gcloud run jobs update --image`, which needs roles/run.developer on the Job
# and actAs on the account the new revision runs as. Each grant names one Job
# or one account, as the deployer's registry grant names one repository.
resource "google_cloud_run_v2_job_iam_member" "analytics_deployer_developer" {
  for_each = google_cloud_run_v2_job.analytics

  project  = each.value.project
  location = each.value.location
  name     = each.value.name
  role     = "roles/run.developer"
  member   = google_service_account.analytics_deployer.member
}

# One grant per account. The freshness Job runs as the dbt Job's account,
# whose grant is the dbt entry's, since two resources holding one binding
# would remove it for both when either is destroyed.
resource "google_service_account_iam_member" "analytics_deployer_act_as" {
  for_each = { for name, job in local.analytics_jobs_created : name => job if name != "freshness" }

  service_account_id = each.value.account.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.analytics_deployer.member
}

# ─────────────────────────────────────────────────────────────────────────────
# Scheduler
# ─────────────────────────────────────────────────────────────────────────────

# One identity for the four triggers. It runs as nothing and holds only
# roles/run.invoker on each Job, which runs it with no overrides.
resource "google_service_account" "analytics_scheduler" {
  count = local.analytics_jobs_count

  account_id   = "${var.namespace}-analytics-scheduler"
  display_name = "${var.namespace} analytics Jobs Cloud Scheduler trigger"
  description  = "Starts the analytics Jobs on their schedules. Holds roles/run.invoker on each Job and nothing else."
}

resource "google_cloud_run_v2_job_iam_member" "analytics_scheduler_invoker" {
  for_each = google_cloud_run_v2_job.analytics

  project  = each.value.project
  location = each.value.location
  name     = each.value.name
  role     = "roles/run.invoker"
  member   = google_service_account.analytics_scheduler[0].member
}

# The Cloud Run Admin API's run call, as the ai stack's langfuse_export
# trigger makes.
resource "google_cloud_scheduler_job" "analytics" {
  for_each = local.analytics_job_triggers

  name      = "${var.namespace}-analytics-${each.key}-tick"
  region    = var.region
  schedule  = each.value.schedule
  time_zone = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.analytics[each.key].name}:run"

    oauth_token {
      service_account_email = google_service_account.analytics_scheduler[0].email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.analytics_jobs,
    google_cloud_run_v2_job_iam_member.analytics_scheduler_invoker,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Alerts
# ─────────────────────────────────────────────────────────────────────────────

# The hourly Jobs alert when no execution has succeeded for three hours, as
# export_job_not_succeeding (alerts.tf) does for the export Jobs. That covers
# a failing run, a paused trigger and a deleted Job alike. A single failed
# hourly run raises nothing, since the next one retries it: the dbt build
# replaces the last three days, and the edge extract reads objects for three
# days after they land. The dbt alert waits for the dbt trigger, so the
# cutover's one-off executions start no absence clock. The freshness Job is
# hourly too, so the same three hours catch a paused trigger or a deleted
# Job, and analytics_job_failed below also alerts on each failed run.
resource "google_monitoring_alert_policy" "analytics_job_not_succeeding" {
  for_each = { for name, job in local.analytics_job_triggers : name => job if contains(["dbt", "edge", "freshness"], name) }

  project      = var.project_id
  display_name = "${google_cloud_run_v2_job.analytics[each.key].name} Job not succeeding"
  combiner     = "OR"

  conditions {
    display_name = "no succeeded ${google_cloud_run_v2_job.analytics[each.key].name} execution for 10800s"

    condition_absent {
      filter   = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${google_cloud_run_v2_job.analytics[each.key].name}\" AND resource.labels.location=\"${var.region}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result=\"succeeded\""
      duration = "10800s"

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

# A failed run of these Jobs alerts at once, as export_job_failed (alerts.tf)
# does. The grader runs once a day, so a failed run waits a day for its
# retry. A failed freshness run is the alert itself: a source the dbt build
# reads has stopped arriving, or the build has stopped writing it.
resource "google_monitoring_alert_policy" "analytics_job_failed" {
  for_each = { for name, job in local.analytics_jobs_created : name => job if contains(["grade", "freshness"], name) }

  project      = var.project_id
  display_name = "${google_cloud_run_v2_job.analytics[each.key].name} Job execution failed"
  combiner     = "OR"

  conditions {
    display_name = "${google_cloud_run_v2_job.analytics[each.key].name} execution completed as failed"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${google_cloud_run_v2_job.analytics[each.key].name}\" AND resource.labels.location=\"${var.region}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result=\"failed\""
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

# One day's schedule plus two hours' slack. A condition_absent caps the
# absence at 23.5 hours, so this is a PromQL condition, as
# logs_daily_not_succeeding (alerts.tf) is: it returns 1 when the window's
# succeeded executions sum to less than one, and when the series is absent.
# It is evaluated over stored data, so it alerts within minutes of the flag
# being switched on and closes after the Job's first success.
resource "google_monitoring_alert_policy" "analytics_grade_not_succeeding" {
  count = local.analytics_jobs_count

  project      = var.project_id
  display_name = "${google_cloud_run_v2_job.analytics["grade"].name} Job not succeeding"
  combiner     = "OR"

  conditions {
    display_name = "no succeeded ${google_cloud_run_v2_job.analytics["grade"].name} execution in 26 hours"

    condition_prometheus_query_language {
      query               = "(sum(sum_over_time(run_googleapis_com:job_completed_execution_count{monitored_resource=\"cloud_run_job\",job_name=\"${google_cloud_run_v2_job.analytics["grade"].name}\",location=\"${var.region}\",result=\"succeeded\"}[26h])) < 1) or absent_over_time(run_googleapis_com:job_completed_execution_count{monitored_resource=\"cloud_run_job\",job_name=\"${google_cloud_run_v2_job.analytics["grade"].name}\",location=\"${var.region}\",result=\"succeeded\"}[26h])"
      duration            = "0s"
      evaluation_interval = "300s"
    }
  }

  notification_channels = local.alert_notification_channels

  alert_strategy {
    auto_close = "604800s"
  }
}

# The edge extract records an object it cannot decompress as unreadable, and
# one EDGE_REJECT_OBJECTS names as rejected, and reads neither again. An
# object deleted between the listing and the read is skipped unrecorded. In
# all three cases the object's deliveries are lost however the run ends. The
# run's last stdout line, `run summary:` followed by key=value counts, carries
# `rejected=<n>`, `unreadable=<n>` and `deleted=<n>`, and this metric counts
# the summaries where any of them is above zero, with the filter the analytics
# repository's README documents. Counts carry no leading zero, so [1-9]
# matches any count from 1 up.
resource "google_logging_metric" "analytics_edge_objects_lost" {
  count = local.analytics_jobs_count

  name    = "${var.namespace}-analytics-edge-objects-lost"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="${google_cloud_run_v2_job.analytics["edge"].name}"
    resource.labels.location="${var.region}"
    textPayload=~"^run summary: .* (rejected|unreadable|deleted)=[1-9]"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# Waits out the new metric's propagation to Cloud Monitoring before the alert
# policy names it, as logs_daily_failed_metric_propagation (logs_daily.tf)
# does.
resource "time_sleep" "analytics_edge_objects_lost_metric_propagation" {
  count = local.analytics_jobs_count

  depends_on      = [google_logging_metric.analytics_edge_objects_lost]
  create_duration = "120s"
}

resource "google_monitoring_alert_policy" "analytics_edge_objects_lost" {
  count = local.analytics_jobs_count

  project      = var.project_id
  display_name = "${google_cloud_run_v2_job.analytics["edge"].name} lost rejected, unreadable or deleted objects"
  combiner     = "OR"

  depends_on = [time_sleep.analytics_edge_objects_lost_metric_propagation]

  conditions {
    display_name = "run summary with rejected, unreadable or deleted above zero"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.analytics_edge_objects_lost[0].name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      # ALIGN_SUM, since Cloud Logging writes a zero sample in the interval
      # beside each non-zero one, which ALIGN_COUNT would count as a run.
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = local.alert_notification_channels

  alert_strategy {
    auto_close = "3600s"
  }
}
