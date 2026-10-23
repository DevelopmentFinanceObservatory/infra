# Cloud Run logs routed into a Log Analytics bucket, which BigQuery reads
# through the linked dataset dfo_logs. The sink copies entries, so the
# _Default bucket keeps receiving them unchanged. Sinks route only entries
# written after they exist, so dfo_logs starts empty on the first apply.
resource "google_logging_project_bucket_config" "telemetry" {
  project          = var.project_id
  location         = local.log_location
  bucket_id        = "${var.namespace}-telemetry"
  description      = "Cloud Run request logs and service and job stdout and stderr, for logs_daily."
  retention_days   = var.log_retention_days
  enable_analytics = true

  depends_on = [google_project_service.apis]
}

# Matches by resource type with no service list, so a new or renamed service
# or job is routed with no change here. Request logs carry status, latency and
# URL; stdout and stderr carry the services' structured logs. The load
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

# BigQuery roles decide who can query dfo_logs, whose entries hold request
# IPs and user agents. The logs_daily query account reads it by its dataset
# grant (logs_daily.tf). Project-level BigQuery data roles reach it too:
# today the applier's roles/bigquery.dataOwner, dfo-prod-dc-ing-pst-sa's
# roles/bigquery.dataEditor, and the project owners. If the linked dataset
# carries BigQuery's default projectWriters and projectReaders entries, the
# project's editors (the default compute service account and the Google APIs
# service agent) and viewers (dfo-infra-planner) read it as well. Readers of
# the reporting dataset get no access here.
resource "google_logging_linked_dataset" "telemetry" {
  link_id     = "dfo_logs"
  bucket      = google_logging_project_bucket_config.telemetry.id
  description = "Log Analytics view of the ${google_logging_project_bucket_config.telemetry.bucket_id} bucket."
}
