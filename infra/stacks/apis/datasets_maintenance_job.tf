# The Cloud Run Job behind dfo-apis's `datasets-maintenance` console script.
# It runs the same image as the service with the entrypoint
# `datasets-maintenance`, and each execution names one task in its args:
#
#   sweep           read-only reconciliation of both artifact tiers against
#                   the artifact inventory, logging counts per tier
#   age-operations  fails abandoned rows of datasets.operation, then
#                   deletes done and failed rows older than the advertised
#                   retention of 30 days
#   backfill-frame1 converts pinned frame1 JSON to the canonical Parquet
#                   frame; run by hand once per environment, never on a
#                   schedule
#
# The Job runs as the apis runtime identity: the tasks need exactly what the
# service has (object create and view on the working and pinned buckets, the
# runtime Postgres role), and a second identity would repeat those grants. The
# runtime Postgres role holds SELECT, INSERT, UPDATE and DELETE on every
# table in the `datasets` schema through dataset_store migration
# 0001_bootstrap.sql's ALTER DEFAULT PRIVILEGES, so age-operations can update
# and delete rows of datasets.operation without a further grant.

resource "google_cloud_run_v2_job" "datasets_maintenance" {
  name     = "${var.namespace}-datasets-maintenance"
  location = var.region
  project  = var.project_id

  deletion_protection = var.stateless_deletion_protection

  template {
    template {
      service_account = module.apis_service.runtime_service_account_email

      # Every task is safe to run again (the sweep only reads, age-operations
      # fails abandoned rows and deletes by age, and the backfill only adds
      # objects and links), and
      # the next daily trigger covers a failed scheduled run, so a failed
      # task waits for that run or an operator.
      max_retries = 0
      timeout     = "3600s"

      containers {
        image   = coalesce(var.datasets_maintenance_bootstrap_image, local.live_apis_image)
        command = ["datasets-maintenance"]

        # No default args: a missing task name fails the argument parser, so
        # an execution that names no task fails instead of exiting 0.

        resources {
          limits = {
            cpu    = "1"
            memory = "2Gi"
          }
        }

        env {
          name  = "DATASETS_ARTIFACT_BUCKET_WORKING"
          value = var.datasets_working_bucket_name
        }

        env {
          name  = "DATASETS_ARTIFACT_BUCKET_PINNED"
          value = var.datasets_pinned_bucket_name
        }

        # The same Cloud SQL Python Connector path as the apis service
        # (main.tf): the runtime identity logs in over IAM, so no password is
        # set.
        env {
          name  = "DATASET_STORE_INSTANCE_CONNECTION_NAME"
          value = var.platform_postgres_connection_name
        }

        env {
          name  = "DATASET_STORE_RUNTIME_DB_USER"
          value = google_sql_user.datasets_runtime.name
        }

        # The deadline age-operations judges an abandoned operation by, the
        # value the apis service and the worker read.
        env {
          name  = "DATASETS_OPERATION_DEADLINE_SECONDS"
          value = tostring(local.datasets_operation_deadline_seconds)
        }
      }

      # The same PSC subnet and egress as the service and the other Jobs.
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
    google_storage_bucket_iam_member.datasets_working_creator,
    google_storage_bucket_iam_member.datasets_working_viewer,
    google_storage_bucket_iam_member.datasets_pinned_creator,
    google_storage_bucket_iam_member.datasets_pinned_viewer,
    google_project_iam_member.datasets_cloudsql_client,
    google_project_iam_member.datasets_cloudsql_instance_user,
    google_sql_user.datasets_runtime,
  ]
}

# Bootstrap only, the same rationale datasets_migrate_job.tf records for its
# own bootstrap image: a real dfo-apis image, so an execution against a Job
# the deploy pipeline has not yet pointed at an image carrying the
# console script fails on the missing command instead of exiting 0.
variable "datasets_maintenance_bootstrap_image" {
  description = "Overrides the image the maintenance Job is created with. The deploy pipeline replaces it per release; null (the default) bootstraps from local.live_apis_image, the tag the apis service is currently running."
  type        = string
  default     = null
}

# The deployer updates the Job's image and runs `backfill-frame1` by hand. The
# actAs grant on the runtime identity comes from module.apis_service's
# deployer_members.
resource "google_cloud_run_v2_job_iam_member" "datasets_maintenance_deployer_run_developer" {
  project  = google_cloud_run_v2_job.datasets_maintenance.project
  location = google_cloud_run_v2_job.datasets_maintenance.location
  name     = google_cloud_run_v2_job.datasets_maintenance.name
  role     = "roles/run.developer"
  member   = "serviceAccount:${data.google_service_account.apis_deployer.email}"
}

output "datasets_maintenance_job_name" {
  description = "Name of the maintenance Job. Run a task by hand with `gcloud run jobs execute <name> --args=<task>`."
  value       = google_cloud_run_v2_job.datasets_maintenance.name
}

# ─────────────────────────────────────────────────────────────────────────────
# Scheduler
# ─────────────────────────────────────────────────────────────────────────────

# A dedicated identity purely to authenticate the Scheduler->Cloud Run Admin
# API call; it never runs as anything and holds no other grant.
resource "google_service_account" "datasets_maintenance_scheduler" {
  project      = var.project_id
  account_id   = "${var.namespace}-dsmaint-scheduler"
  display_name = "Datasets maintenance Job Cloud Scheduler trigger"
}

# Running a Job with per-execution args is an override, which needs
# run.jobs.runWithOverrides; roles/run.invoker carries only run.jobs.run.
# roles/run.jobsExecutorWithOverrides carries both and nothing else beyond
# cancelling executions, scoped to this one Job.
resource "google_cloud_run_v2_job_iam_member" "datasets_maintenance_scheduler_executor" {
  project  = google_cloud_run_v2_job.datasets_maintenance.project
  location = google_cloud_run_v2_job.datasets_maintenance.location
  name     = google_cloud_run_v2_job.datasets_maintenance.name
  role     = "roles/run.jobsExecutorWithOverrides"
  member   = google_service_account.datasets_maintenance_scheduler.member
}

locals {
  # Daily, half an hour apart so the two tasks never share the database
  # connection budget. Each name is the task passed to `datasets-maintenance`.
  datasets_maintenance_schedules = {
    sweep          = "0 3 * * *"
    age-operations = "30 3 * * *"
  }
}

# Cloud Run Admin API's run call with a container args override, the same
# oauth_token target coverage.tf uses.
resource "google_cloud_scheduler_job" "datasets_maintenance" {
  for_each = local.datasets_maintenance_schedules

  name      = "${var.namespace}-datasets-${each.key}"
  project   = var.project_id
  region    = var.region
  schedule  = each.value
  time_zone = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.datasets_maintenance.name}:run"

    headers = {
      "Content-Type" = "application/json"
    }
    body = base64encode(jsonencode({
      overrides = {
        containerOverrides = [{ args = [each.key] }]
      }
    }))

    oauth_token {
      service_account_email = google_service_account.datasets_maintenance_scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.cloudscheduler,
    google_cloud_run_v2_job_iam_member.datasets_maintenance_scheduler_executor,
  ]
}
