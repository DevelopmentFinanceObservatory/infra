# A Log Analytics bucket that keeps the usage log lines for SQL: the website's
# request and event lines and the apis service's resolve lines. Created only
# when usage_logs is set. One sink routes the lines here. They reach _Default
# as well, which this stack leaves alone. A linked BigQuery dataset exposes
# the bucket to BigQuery, beside billing_export. The foundation README's
# "Usage logs" section has example queries.
#
# Three changes cannot be undone: the analytics upgrade, the bucket's
# location, and the bucket id, which stays reserved for 7 days after a
# delete, so unsetting usage_logs and setting it again within a week fails
# apply.
locals {
  usage_logs_enabled = var.usage_logs != null
}

resource "google_logging_project_bucket_config" "usage_logs" {
  count = local.usage_logs_enabled ? 1 : 0

  project        = var.project_id
  bucket_id      = "usage_logs"
  description    = "Website request and event lines and apis resolve lines, kept for SQL through the linked usage_logs dataset."
  location       = "eu"
  retention_days = var.usage_logs.retention_days

  # Log Analytics stores jsonPayload as one JSON column, so a payload whose
  # fields change type or shape between lines (the resolve line's
  # parts_by_step holds nulls; event props vary by event name) loses no rows.
  enable_analytics = true
}

# The website lines come from logRequest (message "request") and track()
# (message "event") in dfo-website, each one JSON object on stdout. The apis
# line is `resolve {json}`, logged as text by the search.engine.core logger
# through dfo_platform.cloud_logging.JsonFormatter.
resource "google_logging_project_sink" "usage_logs" {
  count = local.usage_logs_enabled ? 1 : 0

  name        = "usage-logs"
  description = "Usage log lines into the usage_logs Log Analytics bucket."
  destination = "logging.googleapis.com/${google_logging_project_bucket_config.usage_logs[0].id}"
  filter      = <<-EOT
    resource.type="cloud_run_revision" AND (
      (resource.labels.service_name="${var.usage_logs.website_service}" AND (jsonPayload.message="request" OR jsonPayload.message="event"))
      OR (resource.labels.service_name="${var.usage_logs.apis_service}" AND jsonPayload.logger="search.engine.core" AND jsonPayload.message=~"^resolve ")
    )
  EOT

  # A sink into a bucket in its own project writes with the Logging service's
  # own access, so its writer identity needs no grant.
}

resource "google_logging_linked_dataset" "usage_logs" {
  count = local.usage_logs_enabled ? 1 : 0

  link_id     = "usage_logs"
  bucket      = google_logging_project_bucket_config.usage_logs[0].id
  description = "Read-only BigQuery views of the usage_logs bucket."

  # The linked dataset is a BigQuery dataset, so the API is enabled first
  # (google_project_service.apis in main.tf).
  depends_on = [google_project_service.apis]
}
