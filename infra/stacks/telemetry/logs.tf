# Cloud Run logs routed into a Log Analytics bucket, which BigQuery reads
# through the linked dataset dfo_logs. The sink copies entries, so the
# _Default bucket keeps receiving them unchanged. Sinks route only entries
# written after they exist, so dfo_logs starts empty on the first apply.
resource "google_logging_project_bucket_config" "telemetry" {
  project          = var.project_id
  location         = local.log_location
  bucket_id        = "${var.namespace}-telemetry"
  description      = "Cloud Run request logs and service and job stdout and stderr, for the analytics dbt build."
  retention_days   = var.log_retention_days
  enable_analytics = true

  depends_on = [google_project_service.apis]
}

# Matches by resource type with no service list, so a new or renamed service
# or job is routed with no change here. Request logs carry status, latency and
# URL. Stdout and stderr carry the services' structured logs. The load
# balancer's logs and the datacommons service's nginx access log stay out.
# So do the website's usage-event lines (jsonPayload.message "event" on its
# stdout), which repeat the Postgres event table the website export copies,
# and whose props carry the first 500 characters of each search query.
# A sink to a bucket in its own project writes with no grant.
resource "google_logging_project_sink" "telemetry" {
  name        = "${var.namespace}-telemetry"
  description = "Routes Cloud Run request, stdout and stderr logs to the ${google_logging_project_bucket_config.telemetry.bucket_id} bucket."
  destination = "logging.googleapis.com/${google_logging_project_bucket_config.telemetry.id}"

  filter = <<-EOT
    (resource.type="cloud_run_revision" OR resource.type="cloud_run_job")
    AND (log_id("run.googleapis.com/requests") OR log_id("run.googleapis.com/stdout") OR log_id("run.googleapis.com/stderr"))
    AND NOT (resource.labels.service_name="${var.namespace}-website" AND jsonPayload.message="event")
  EOT

  unique_writer_identity = true
}

# BigQuery roles decide who can query dfo_logs, whose entries hold request IPs
# and user agents. The analytics service accounts and developers read it by
# their dataset grants (analytics.tf). Project-level BigQuery data roles reach
# it too: today the applier's roles/bigquery.dataOwner, dfo-prod-dc-ing-pst-sa's
# roles/bigquery.dataEditor, and the project owners. If the linked dataset
# carries BigQuery's default projectWriters and projectReaders entries, the
# project's editors (the default compute service account and the Google APIs
# service agent) and viewers (dfo-infra-planner) read it as well. Readers of the
# reporting dataset get no access here.
resource "google_logging_linked_dataset" "telemetry" {
  link_id     = "dfo_logs"
  bucket      = google_logging_project_bucket_config.telemetry.id
  description = "Log Analytics view of the ${google_logging_project_bucket_config.telemetry.bucket_id} bucket."
}

# A copy of the logs_daily dataset's seven tables, the only record of the
# raw entries before the sink started on 2026-10-23. backfill_entries holds
# those entries with caller IPs and user agents, so the access block is
# authoritative, unlike every other dataset in this stack: an apply removes any
# grant added outside it, and only the project owners read the archive. No
# google_bigquery_dataset_access names it, and it is not an analytics source
# (analytics.tf).
import {
  to = google_bigquery_dataset.logs_daily_archive
  id = "projects/${var.project_id}/datasets/logs_daily_archive"
}

resource "google_bigquery_dataset" "logs_daily_archive" {
  dataset_id  = "logs_daily_archive"
  location    = local.bigquery_location
  description = "A copy of the logs_daily dataset, taken before its removal. backfill_entries holds raw Cloud Run log entries from before 23 Oct 2026, with caller IPs and user agents, so only project owners can read this dataset."

  labels = {
    purpose = "archive"
  }

  access {
    role          = "OWNER"
    special_group = "projectOwners"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# logs_daily holds the daily aggregates, the backfill table and the entries
# view that logs_daily_archive copies, and nothing reads it. A dataset
# resource being removed cannot set delete_contents_on_destroy, a destroy of
# a dataset that holds tables fails, and both tables carry the provider's
# default deletion protection, so Terraform forgets the three here and README
# "Datasets deleted by hand" gives the bq rm that deletes the dataset.
removed {
  from = google_bigquery_dataset.logs_daily

  lifecycle {
    destroy = false
  }
}

removed {
  from = google_bigquery_table.backfill_entries

  lifecycle {
    destroy = false
  }
}

removed {
  from = google_bigquery_table.entries

  lifecycle {
    destroy = false
  }
}
