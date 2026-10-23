# The Langfuse export: a Cloud Run Job running dfo-ai's
# `python -m harness.langfuse_export` every hour, and the BigQuery dataset it
# loads into. Each run reads observation rows from Langfuse's
# /api/public/v2/observations and replaces one partition of
# `langfuse_export.observations` per UTC day, from the latest loaded day minus
# one through today. The job creates and evolves the table itself, so
# Terraform owns the dataset and IAM only. Prompts, answers, metadata and
# `statusMessage` never reach BigQuery: the job requests no `io` or
# `metadata` field group and copies named fields only.
#
# Prod only. var.langfuse_export_enabled is false in dfo-dev, where every
# resource here has count 0.

variable "langfuse_export_enabled" {
  description = "Creates the langfuse_export dataset, the export Job, its hourly trigger and their identities. On in dfo-prod, off in dfo-dev."
  type        = bool
  default     = false
}

locals {
  langfuse_export_count = var.langfuse_export_enabled ? 1 : 0
}

# Both APIs are already on in prod (the dcp stack enables BigQuery and the
# apis stack Cloud Scheduler). Declaring them here keeps this file's applies
# independent of those stacks; disable_on_destroy = false leaves them on for
# the other owners.
resource "google_project_service" "langfuse_export_bigquery" {
  count = local.langfuse_export_count

  project            = var.project_id
  service            = "bigquery.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "langfuse_export_cloudscheduler" {
  count = local.langfuse_export_count

  project            = var.project_id
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
}

# ─────────────────────────────────────────────────────────────────────────────
# Dataset
# ─────────────────────────────────────────────────────────────────────────────

# EU multi-region, the location of every dataset the reporting views read.
# The location cannot change after creation.
resource "google_bigquery_dataset" "langfuse_export" {
  count = local.langfuse_export_count

  project     = var.project_id
  dataset_id  = "langfuse_export"
  location    = "EU"
  description = "Langfuse observation rows (ids, names, times, tokens, cost; no prompt or answer text), loaded hourly by the ${var.namespace}-langfuse-export Job."

  # No access blocks: every grant on this dataset is a
  # google_bigquery_dataset_access resource, here and in the telemetry stack's
  # authorised views. Access blocks would make the dataset's ACL authoritative
  # and drop those entries on the next apply.

  depends_on = [google_project_service.langfuse_export_bigquery]
}

# ─────────────────────────────────────────────────────────────────────────────
# Job identity and its access
# ─────────────────────────────────────────────────────────────────────────────

# A dedicated identity, separate from module.ai_service's runtime account: the
# public service has no reason to write BigQuery, and the job has no reason to
# hold the service's Gemini, token and session-store access.
resource "google_service_account" "langfuse_export" {
  count = local.langfuse_export_count

  project      = var.project_id
  account_id   = "${var.namespace}-langfuse-export"
  display_name = "Langfuse export Job"
}

# Running a load job is authorised at the project level only; this grant reads
# and writes no table by itself.
resource "google_project_iam_member" "langfuse_export_bigquery_job_user" {
  count = local.langfuse_export_count

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.langfuse_export[0].member
}

# WRITER is the dataset-level form of roles/bigquery.dataEditor: create the
# table, load partitions with WRITE_TRUNCATE, delete an empty day's partition,
# and read MAX(start_time) for the window. The API stores a predefined role
# here as WRITER, so naming the predefined role would plan a change on every
# apply.
resource "google_bigquery_dataset_access" "langfuse_export_writer" {
  count = local.langfuse_export_count

  project       = var.project_id
  dataset_id    = google_bigquery_dataset.langfuse_export[0].dataset_id
  role          = "WRITER"
  user_by_email = google_service_account.langfuse_export[0].email
}

# The same two secrets the service mounts, read at `latest` like the service's
# mounts.
resource "google_secret_manager_secret_iam_member" "langfuse_export_secret_access" {
  for_each = var.langfuse_export_enabled ? {
    public = data.google_secret_manager_secret.langfuse_public_key.secret_id
    secret = data.google_secret_manager_secret.langfuse_secret_key.secret_id
  } : {}

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.langfuse_export[0].member
}

# actAs so the deployer can update the Job's image, which creates a new Job
# revision running as this identity.
resource "google_service_account_iam_member" "langfuse_export_deployer_act_as" {
  count = local.langfuse_export_count

  service_account_id = google_service_account.langfuse_export[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${data.google_service_account.ai_deployer.email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Job
# ─────────────────────────────────────────────────────────────────────────────

resource "google_cloud_run_v2_job" "langfuse_export" {
  count = local.langfuse_export_count

  name     = "${var.namespace}-langfuse-export"
  location = var.region
  project  = var.project_id

  deletion_protection = var.stateless_deletion_protection

  template {
    template {
      service_account = google_service_account.langfuse_export[0].email

      # A run replaces whole days and loads a day only after every Langfuse
      # page for it answered 200, so a failed run leaves BigQuery as it was
      # and the next hourly run reads the same window again. No retry, so a
      # failure caused by Langfuse's rate limit does not repeat at once
      # inside the same bucket.
      max_retries = 0
      # The first backfill from 2026-10-05 is about 110 pages at one request
      # every 2 s, about 4 minutes; an hourly run is about 10 pages. 30
      # minutes also keeps one execution from overlapping the next trigger.
      timeout = "1800s"

      containers {
        # Bootstrap only: the dfo-ai image the service runs now. The dfo-ai
        # deploy workflow moves the Job to each new image with
        # `gcloud run jobs update --image`, and lifecycle.ignore_changes below
        # keeps that from reading as drift. An image older than the export
        # module fails on the missing module instead of exiting 0.
        image   = module.ai_service.image
        command = ["python"]
        args    = ["-m", "harness.langfuse_export"]

        # One day's rows held in memory before its load, 16,909 on the
        # busiest day to 2026-10-23.
        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }

        env {
          name = "LANGFUSE_PUBLIC_KEY"
          value_source {
            secret_key_ref {
              secret  = data.google_secret_manager_secret.langfuse_public_key.secret_id
              version = "latest"
            }
          }
        }

        env {
          name = "LANGFUSE_SECRET_KEY"
          value_source {
            secret_key_ref {
              secret  = data.google_secret_manager_secret.langfuse_secret_key.secret_id
              version = "latest"
            }
          }
        }

        env {
          name  = "LANGFUSE_BASE_URL"
          value = local.langfuse_base_url
        }

        # The environment the service tags its traces with, so the job reads
        # deployed traffic only.
        env {
          name  = "LANGFUSE_EXPORT_ENVIRONMENT"
          value = local.langfuse_tracing_environment
        }

        env {
          name  = "EXPORT_BQ_PROJECT"
          value = var.project_id
        }

        env {
          name  = "EXPORT_BQ_DATASET"
          value = google_bigquery_dataset.langfuse_export[0].dataset_id
        }
      }

      # No vpc_access: the job reaches Langfuse Cloud and BigQuery over the
      # public internet and never opens a database connection.
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
    google_project_iam_member.langfuse_export_bigquery_job_user,
    google_bigquery_dataset_access.langfuse_export_writer,
    google_secret_manager_secret_iam_member.langfuse_export_secret_access,
  ]
}

# The deploy workflow's `gcloud run jobs update --image`, and a manual
# `gcloud run jobs execute` with `--args=--check-day,YYYY-MM-DD`.
resource "google_cloud_run_v2_job_iam_member" "langfuse_export_deployer_run_developer" {
  count = local.langfuse_export_count

  project  = google_cloud_run_v2_job.langfuse_export[0].project
  location = google_cloud_run_v2_job.langfuse_export[0].location
  name     = google_cloud_run_v2_job.langfuse_export[0].name
  role     = "roles/run.developer"
  member   = "serviceAccount:${data.google_service_account.ai_deployer.email}"
}

output "langfuse_export_job_name" {
  description = "Name of the Langfuse export Job, null where the export is off. dfo-ai's JOB_LANGFUSE_EXPORT in this environment's GitHub Environment."
  value       = one(google_cloud_run_v2_job.langfuse_export[*].name)
}

# ─────────────────────────────────────────────────────────────────────────────
# Scheduler
# ─────────────────────────────────────────────────────────────────────────────

# A dedicated identity purely to authenticate the Scheduler->Cloud Run Admin
# API call; it never runs as anything and holds no other grant.
resource "google_service_account" "langfuse_export_scheduler" {
  count = local.langfuse_export_count

  project      = var.project_id
  account_id   = "${var.namespace}-langfuse-scheduler"
  display_name = "Langfuse export Job Cloud Scheduler trigger"
}

# run.jobs.run on this one Job. The trigger passes no overrides, so
# roles/run.invoker is enough.
resource "google_cloud_run_v2_job_iam_member" "langfuse_export_scheduler_invoker" {
  count = local.langfuse_export_count

  project  = google_cloud_run_v2_job.langfuse_export[0].project
  location = google_cloud_run_v2_job.langfuse_export[0].location
  name     = google_cloud_run_v2_job.langfuse_export[0].name
  role     = "roles/run.invoker"
  member   = google_service_account.langfuse_export_scheduler[0].member
}

# The Cloud Run Admin API's run call, the same oauth_token target the apis
# stack's coverage.tf uses.
resource "google_cloud_scheduler_job" "langfuse_export" {
  count = local.langfuse_export_count

  name      = "${var.namespace}-langfuse-export-tick"
  project   = var.project_id
  region    = var.region
  schedule  = "0 * * * *"
  time_zone = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.langfuse_export[0].name}:run"

    oauth_token {
      service_account_email = google_service_account.langfuse_export_scheduler[0].email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.langfuse_export_cloudscheduler,
    google_cloud_run_v2_job_iam_member.langfuse_export_scheduler_invoker,
  ]
}
