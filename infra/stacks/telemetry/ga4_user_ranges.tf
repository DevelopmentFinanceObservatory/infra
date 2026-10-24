# GA4 unique users over fixed date ranges, from the Data API, which removes
# repeat visitors over any range it is asked for. GA4's active users do not
# sum across days, and its BigQuery export starts later than the site, so this
# is the only source of unique users over a range reaching back before the
# export. A Cloud Workflows workflow (ga4_user_ranges.yaml) runs once a day as
# the web history service account (history.tf), which holds GA4 Viewer and
# WRITER on web_history, and replaces web_history.ga4_user_ranges whole, so
# GA4's late revisions to a range land on the next run.
locals {
  ga4_user_ranges_name = "${var.namespace}-ga4-user-ranges"
  # The site's launch day, the first day of since_floor and of the first week
  # and month.
  ga4_user_ranges_floor = "2026-10-05"
}

resource "google_project_service" "ga4_user_ranges_apis" {
  for_each = toset([
    "workflows.googleapis.com",
    "cloudscheduler.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

# Terraform owns the table, so the view in dfo_reporting can name it before
# the first run, and each run replaces its rows and keeps its schema.
resource "google_bigquery_table" "ga4_user_ranges" {
  dataset_id  = google_bigquery_dataset.web_history.dataset_id
  table_id    = "ga4_user_ranges"
  description = "GA4 Data API users over each range the ${local.ga4_user_ranges_name} workflow lists, replaced whole by each run."

  # The next run rebuilds every row.
  deletion_protection = false

  schema = jsonencode([
    { name = "range_kind", type = "STRING", mode = "REQUIRED", description = "since_floor, last_7, last_28, week or month." },
    { name = "range_start", type = "DATE", mode = "REQUIRED", description = "First day of the range, in the GA4 property's reporting time zone." },
    { name = "range_end", type = "DATE", mode = "REQUIRED", description = "Last day of the range, in the GA4 property's reporting time zone." },
    { name = "active_users", type = "INT64", mode = "REQUIRED", description = "GA4 activeUsers over the range." },
    { name = "total_users", type = "INT64", mode = "REQUIRED", description = "GA4 totalUsers over the range." },
    { name = "new_users", type = "INT64", mode = "REQUIRED", description = "GA4 newUsers over the range." },
    { name = "fetched_at", type = "TIMESTAMP", mode = "REQUIRED", description = "When the run that wrote the row read the Data API." },
  ])
}

resource "google_workflows_workflow" "ga4_user_ranges" {
  name            = local.ga4_user_ranges_name
  region          = var.region
  description     = "Replaces web_history.ga4_user_ranges with GA4 Data API users over each range."
  service_account = google_service_account.web_history.id
  source_contents = templatefile("${path.module}/ga4_user_ranges.yaml", {
    ga4_property = trimprefix(var.ga4_export_dataset, "analytics_")
    project      = var.project_id
    location     = local.bigquery_location
    floor        = local.ga4_user_ranges_floor
    requests_sql = file("${path.module}/sql/ga4_user_ranges_requests.sql")
    replace_sql  = <<-SQL
      MERGE `${var.project_id}.${google_bigquery_table.ga4_user_ranges.dataset_id}.${google_bigquery_table.ga4_user_ranges.table_id}` AS t
      USING (
      ${file("${path.module}/sql/ga4_user_ranges_rows.sql")}
      ) AS s
      ON FALSE
      WHEN NOT MATCHED BY SOURCE THEN DELETE
      WHEN NOT MATCHED THEN INSERT ROW
    SQL
  })

  depends_on = [google_project_service.ga4_user_ranges_apis]
}

# A dedicated identity for the Scheduler's call to the Workflow Executions
# API. It runs as nothing and holds no other grant. Workflows has no
# per-workflow IAM, so the invoker role is on the project.
resource "google_service_account" "ga4_user_ranges_scheduler" {
  account_id   = "${var.namespace}-ga4-ranges-sch"
  display_name = "${local.ga4_user_ranges_name} Cloud Scheduler trigger"
}

resource "google_project_iam_member" "ga4_user_ranges_scheduler_invoker" {
  project = var.project_id
  role    = "roles/workflows.invoker"
  member  = google_service_account.ga4_user_ranges_scheduler.member
}

# 06:00 UTC, when yesterday has been over for six hours in the property's
# time zone (Etc/GMT). GA4 keeps revising a day for 2 to 3 days, and the
# next run takes the revisions.
resource "google_cloud_scheduler_job" "ga4_user_ranges" {
  name      = local.ga4_user_ranges_name
  project   = var.project_id
  region    = var.region
  schedule  = "0 6 * * *"
  time_zone = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/${google_workflows_workflow.ga4_user_ranges.id}/executions"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode("{}")

    oauth_token {
      service_account_email = google_service_account.ga4_user_ranges_scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.ga4_user_ranges_apis,
    google_project_iam_member.ga4_user_ranges_scheduler_invoker,
  ]
}

# Each failed execution, scheduled or by hand: an API error, a range with no
# row, or a failed query.
resource "google_monitoring_alert_policy" "ga4_user_ranges_failed" {
  project      = var.project_id
  display_name = "${local.ga4_user_ranges_name} workflow execution failed"
  combiner     = "OR"

  conditions {
    display_name = "${local.ga4_user_ranges_name} execution finished as failed"

    condition_threshold {
      filter          = "resource.type=\"workflows.googleapis.com/Workflow\" AND resource.labels.workflow_id=\"${local.ga4_user_ranges_name}\" AND resource.labels.location=\"${var.region}\" AND metric.type=\"workflows.googleapis.com/finished_execution_count\" AND metric.labels.status=\"FAILED\""
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
    auto_close = "86400s"
  }
}
