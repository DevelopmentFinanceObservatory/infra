# The analytics repository's eight scheduled Cloud Run Jobs, their Cloud
# Scheduler triggers and their alerts. All eight run the one image the
# repository's Deploy workflow pushes to the analytics Artifact Registry
# repository (analytics.tf), and each Job's args pick the command, since the
# image has no entrypoint:
#
#   dfo-prod-analytics-dbt        dbt build --target prod, hourly at minute 25
#   dfo-prod-analytics-edge       python -m dfo_analytics.extract.edge, hourly at minute 5
#   dfo-prod-analytics-grade      python -m dfo_analytics.grade, daily at 04:30 UTC
#   dfo-prod-analytics-freshness  dbt source freshness --target prod, hourly at minute 50
#   dfo-prod-analytics-repos      python -m dfo_analytics.repos, Mondays at 04:00 UTC
#   dfo-prod-analytics-lighthouse python -m dfo_analytics.lighthouse, Mondays at 05:00 UTC
#   dfo-prod-analytics-replay     python -m dfo_analytics.replay, Mondays at 06:00 UTC
#   dfo-prod-analytics-citations  python -m dfo_analytics.citations, the 1st of each month at 06:00 UTC
#
# var.analytics_jobs_enabled creates everything in this file, the
# freshness Job also waits for var.analytics_dbt_schedule_enabled, and each
# probe's Scheduler trigger and absence alert wait for its entry in
# var.analytics_probes_enabled. The
# datasets the Jobs write, their accounts and those accounts' dataset grants
# live in analytics.tf and exist whatever the flag says. README "Analytics jobs" gives
# the order to switch it on.

variable "analytics_jobs_enabled" {
  description = "Creates the analytics Jobs, their Scheduler triggers and alerts, and the grants only a running Job needs (the edge logs bucket, the secrets, the replay Job's invoker grant on the apis service, the deployer's). Needs analytics_jobs_image."
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

# One switch per probe for its trigger and its absence alert. The probe's Job,
# account, secrets and tables exist whatever it says, so a canary execution
# can run before the trigger does (README "Analytics jobs").
variable "analytics_probes_enabled" {
  description = "Creates a probe's Cloud Scheduler trigger and its not-succeeding alert, by probe name (repos, lighthouse, replay, citations). A probe missing from the map, or false, keeps its Job and has no trigger and no absence alert. Needs analytics_jobs_enabled. Switch a probe on after its canary execution has written valid rows."
  type        = map(bool)
  default = {
    repos      = false
    lighthouse = false
    replay     = false
    citations  = false
  }

  validation {
    condition     = length(setsubtract(keys(var.analytics_probes_enabled), ["repos", "lighthouse", "replay", "citations"])) == 0
    error_message = "analytics_probes_enabled keys must be probe names: repos, lighthouse, replay, citations."
  }

  validation {
    condition     = !anytrue(values(var.analytics_probes_enabled)) || var.analytics_jobs_enabled
    error_message = "analytics_probes_enabled needs analytics_jobs_enabled."
  }
}

variable "analytics_grade_decision_backend" {
  description = "The decision model the grade Job asks, set as GRADE_DECISION_BACKEND: jev (TypeSafe) or gemini. The Job mounts only that backend's key, from analytics_grade_backend_keys, so a backend's secret needs a version only while it is selected."
  type        = string
  default     = "jev"

  validation {
    condition     = contains(["jev", "gemini"], var.analytics_grade_decision_backend)
    error_message = "analytics_grade_decision_backend must be jev or gemini."
  }
}

locals {
  # Each grader backend's key variable and secret. The grade Job mounts the
  # selected backend's alone.
  analytics_grade_backend_keys = {
    jev    = { variable = "TYPESAFE_API_KEY", secret = google_secret_manager_secret.analytics_grader_typesafe.secret_id }
    gemini = { variable = "GOOGLE_API_KEY", secret = google_secret_manager_secret.analytics_grader_gemini.secret_id }
  }
  analytics_grade_backend_key = local.analytics_grade_backend_keys[var.analytics_grade_decision_backend]
}

locals {
  analytics_jobs_count = var.analytics_jobs_enabled ? 1 : 0

  # The probes, each with the hours its absence alert looks back (the weekly
  # period plus a day, or the monthly period plus four days) and the least
  # evaluation interval Cloud Monitoring allows for a PromQL condition that
  # looks that far back: 1 hour from 8 to 16 days, 6 hours from 32 to 93 days
  # (docs.cloud.google.com/monitoring/alerts/using-promql).
  analytics_probes = {
    repos      = { lookback_hours = 192, evaluation_interval = "3600s" }
    lighthouse = { lookback_hours = 192, evaluation_interval = "3600s" }
    replay     = { lookback_hours = 192, evaluation_interval = "3600s" }
    citations  = { lookback_hours = 840, evaluation_interval = "21600s" }
  }

  analytics_probes_active = [for name in keys(local.analytics_probes) : name if lookup(var.analytics_probes_enabled, name, false)]

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

  # The apis service the replay Job calls, by its deterministic Cloud Run URL,
  # which is also the audience of the ID token the Job sends, since prod's
  # apis service admits only callers holding roles/run.invoker
  # (analytics_replay_apis_invoker below). The name follows the apis stack's
  # "${var.namespace}-apis".
  analytics_apis_service_name = "${var.namespace}-apis"
  analytics_apis_url          = "https://${local.analytics_apis_service_name}-${data.google_project.this.number}.${var.region}.run.app"

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
        GRADE_DECISION_BACKEND      = var.analytics_grade_decision_backend
        LANGFUSE_BASE_URL           = local.analytics_langfuse_base_url
        LANGFUSE_EXPORT_ENVIRONMENT = local.analytics_langfuse_environment
      }
      secrets = {
        LANGFUSE_PUBLIC_KEY                          = "${var.namespace}-langfuse-public-key"
        LANGFUSE_SECRET_KEY                          = "${var.namespace}-langfuse-secret-key"
        (local.analytics_grade_backend_key.variable) = local.analytics_grade_backend_key.secret
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
    # The four probes run weekly or monthly, so each timeout is far from the
    # next trigger and sized to the run alone.
    repos = {
      account  = google_service_account.analytics_job["repos"]
      args     = ["python", "-m", "dfo_analytics.repos"]
      timeout  = "3600s"
      memory   = "1Gi"
      schedule = "0 4 * * 1"
      env = {
        REPO_SEARCH_BQ_PROJECT = var.project_id
        REPO_SEARCH_DATASET    = google_bigquery_dataset.analytics_job["repo_search"].dataset_id
      }
      secrets = {
        GITHUB_TOKEN = google_secret_manager_secret.analytics_probe["repos_github_token"].secret_id
      }
    }
    # 15 PageSpeed Insights calls in sequence, each up to 180 seconds with up
    # to three tries and a backoff between tries. The worst case is 15 x 3 x
    # 180 s = 8,100 s, about 2.3 hours with the backoff, so the timeout is 3
    # hours. A run with no failed tries takes a few minutes.
    lighthouse = {
      account  = google_service_account.analytics_job["lighthouse"]
      args     = ["python", "-m", "dfo_analytics.lighthouse"]
      timeout  = "10800s"
      memory   = "1Gi"
      schedule = "0 5 * * 1"
      env = {
        LIGHTHOUSE_BQ_PROJECT = var.project_id
        LIGHTHOUSE_DATASET    = google_bigquery_dataset.analytics_job["lighthouse"].dataset_id
      }
      secrets = {
        PSI_API_KEY = google_secret_manager_secret.analytics_probe["lighthouse_psi_api_key"].secret_id
      }
    }
    # VERIFY_PRINCIPAL is the apis stack's verify principal
    # (verify_principal.tf), which opens the share sample and the analysis
    # verify routes alone. EXPORT_ID_HMAC_KEY is the website stack's event
    # export key (event_export.tf), so the Job's share_digest equals the
    # export's digest of the same shareId.
    replay = {
      account  = google_service_account.analytics_job["replay"]
      args     = ["python", "-m", "dfo_analytics.replay"]
      timeout  = "3600s"
      memory   = "1Gi"
      schedule = "0 6 * * 1"
      env = {
        REPLAY_BQ_PROJECT        = var.project_id
        REPLAY_DATASET           = google_bigquery_dataset.analytics_job["replay_probe"].dataset_id
        REPLAY_APIS_BASE_URL     = local.analytics_apis_url
        REPLAY_ID_TOKEN_AUDIENCE = local.analytics_apis_url
      }
      secrets = {
        VERIFY_PRINCIPAL   = "${var.namespace}-verify-principal"
        EXPORT_ID_HMAC_KEY = "${var.namespace}-website-export-hmac-key"
      }
    }
    # The three providers run in parallel threads, each asking 60 times in
    # sequence, and each ask is capped at 20 minutes. A month's run takes
    # a few hours, bounded by the slowest provider. The 24-hour timeout ends
    # only a pathological month, far inside the monthly trigger.
    citations = {
      account  = google_service_account.analytics_job["citations"]
      args     = ["python", "-m", "dfo_analytics.citations"]
      timeout  = "86400s"
      memory   = "1Gi"
      schedule = "0 6 1 * *"
      env = {
        CITATION_PROBE_BQ_PROJECT = var.project_id
        CITATION_PROBE_DATASET    = google_bigquery_dataset.analytics_job["citation_probe"].dataset_id
      }
      secrets = {
        ANTHROPIC_API_KEY = google_secret_manager_secret.analytics_probe["citations_anthropic_api_key"].secret_id
        OPENAI_API_KEY    = google_secret_manager_secret.analytics_probe["citations_openai_api_key"].secret_id
        GEMINI_API_KEY    = google_secret_manager_secret.analytics_probe["citations_gemini_api_key"].secret_id
      }
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

  # The dbt trigger waits for analytics_dbt_schedule_enabled, and a probe's for
  # its analytics_probes_enabled entry.
  analytics_job_triggers = {
    for name, job in local.analytics_jobs_created : name => job
    if(name != "dbt" || var.analytics_dbt_schedule_enabled) && (!contains(keys(local.analytics_probes), name) || contains(local.analytics_probes_active, name))
  }
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

# The caller HMAC key and the verify principal are owned by the apis stack
# (caller_hmac_key.tf, verify_principal.tf), the export ID key by the website
# stack (event_export.tf), and the Langfuse keys are made by hand and read by
# the ai stack, so each grant is on that secret alone. The edge extract mounts
# the same caller key as the website and dfo-apis, so one client carries one
# caller in all three. The apis stack applies before this one, and the
# website stack has created its key wherever event_export_enabled is on.
resource "google_secret_manager_secret_iam_member" "analytics_job_secret_accessor" {
  for_each = local.analytics_job_secret_grants

  project   = var.project_id
  secret_id = each.value.secret
  role      = "roles/secretmanager.secretAccessor"
  member    = local.analytics_jobs_created[each.value.job].account.member
}

# The replay Job calls the apis service with an ID token minted as its own
# account, and prod's service admits only callers holding roles/run.invoker.
# The grant lives here, beside the account, as the website's and ai's live in
# theirs, since the apis stack applies first and cannot name it.
resource "google_cloud_run_v2_service_iam_member" "analytics_replay_apis_invoker" {
  count = contains(keys(local.analytics_jobs_created), "replay") ? 1 : 0

  project  = var.project_id
  location = var.region
  name     = local.analytics_apis_service_name
  role     = "roles/run.invoker"
  member   = google_service_account.analytics_job["replay"].member
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

      # No vpc_access. The Jobs reach BigQuery, Cloud Storage, Langfuse Cloud,
      # the model and search APIs and the apis service's run.app URL over the
      # public internet.
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
    google_cloud_run_v2_service_iam_member.analytics_replay_apis_invoker,
  ]
}

output "analytics_job_names" {
  description = "Names of the analytics Jobs by command (dbt, edge, grade, freshness, repos, lighthouse, replay, citations), empty while analytics_jobs_enabled is false."
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

# One identity for the triggers. It runs as nothing and holds only
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
# retry, and the four probes a week or a month. A failed freshness run is the
# alert itself: a source the dbt build reads has stopped arriving, or the
# build has stopped writing it. A probe whose trigger stops firing fails no
# run, and analytics_probe_not_succeeding below catches it.
resource "google_monitoring_alert_policy" "analytics_job_failed" {
  for_each = { for name, job in local.analytics_jobs_created : name => job if contains(["grade", "freshness", "repos", "lighthouse", "replay", "citations"], name) }

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

# The probes' version of the grade policy: no succeeded execution in a
# week plus a day for the three weekly probes, and in a month plus four days
# for the monthly citation probe. It catches a paused trigger or a deleted Job,
# which fail no run, whether or not the freshness Job exists. It exists only
# for a probe switched on in var.analytics_probes_enabled, whose canary
# execution has already succeeded, so it opens only if the probe then stops
# succeeding. Cloud Monitoring lets a PromQL condition that looks back 8 to 16
# days evaluate hourly at most, and one that looks back 32 to 93 days every 6
# hours, so the weekly probes evaluate every 3600 s and the citation probe
# every 21600 s (local.analytics_probes).
resource "google_monitoring_alert_policy" "analytics_probe_not_succeeding" {
  for_each = { for name in local.analytics_probes_active : name => local.analytics_probes[name] if contains(keys(local.analytics_jobs_created), name) }

  project      = var.project_id
  display_name = "${google_cloud_run_v2_job.analytics[each.key].name} Job not succeeding"
  combiner     = "OR"

  conditions {
    display_name = "no succeeded ${google_cloud_run_v2_job.analytics[each.key].name} execution in ${each.value.lookback_hours} hours"

    condition_prometheus_query_language {
      query               = "(sum(sum_over_time(run_googleapis_com:job_completed_execution_count{monitored_resource=\"cloud_run_job\",job_name=\"${google_cloud_run_v2_job.analytics[each.key].name}\",location=\"${var.region}\",result=\"succeeded\"}[${each.value.lookback_hours}h])) < 1) or absent_over_time(run_googleapis_com:job_completed_execution_count{monitored_resource=\"cloud_run_job\",job_name=\"${google_cloud_run_v2_job.analytics[each.key].name}\",location=\"${var.region}\",result=\"succeeded\"}[${each.value.lookback_hours}h])"
      duration            = "0s"
      evaluation_interval = each.value.evaluation_interval
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
