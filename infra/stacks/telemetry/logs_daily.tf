# Daily aggregates of the routed Cloud Run logs. The linked dataset reaches
# back only var.log_retention_days, so trends longer than that come from
# here, and the reporting views read here rather than from raw entries.
#
# Terraform owns the dataset, the route function and the scheduled query. The
# query creates its own tables on its first run (sql/logs_daily.sql).
resource "google_bigquery_dataset" "logs_daily" {
  dataset_id  = "logs_daily"
  location    = local.bigquery_location
  description = "Daily Cloud Run request, route, error and deploy aggregates, written by the ${var.namespace}-logs-daily scheduled query."

  # No access blocks: every grant on this dataset is a
  # google_bigquery_dataset_access, which authoritative access blocks would
  # remove on the next apply.

  depends_on = [google_project_service.apis]
}

# The route rule is a pinned function so the scheduled query and anyone
# querying logs_daily by hand normalise URLs the same way.
# tests/normalise_route.test.sh checks the body against recorded prod URLs.
resource "google_bigquery_routine" "normalise_route" {
  dataset_id      = google_bigquery_dataset.logs_daily.dataset_id
  routine_id      = "normalise_route"
  routine_type    = "SCALAR_FUNCTION"
  language        = "SQL"
  description     = "Route of a request URL: the path with id, dcid, hash and number segments as :id."
  definition_body = file("${path.module}/sql/normalise_route.sql")
  return_type     = jsonencode({ typeKind = "STRING" })

  arguments {
    name      = "url"
    data_type = jsonencode({ typeKind = "STRING" })
  }
}

resource "google_service_account" "logs_daily" {
  account_id   = "${var.namespace}-logs-daily"
  display_name = "${var.namespace} logs_daily scheduled query"
  description  = "Runs the logs_daily scheduled query: reads dfo_logs, writes logs_daily."
}

resource "google_project_iam_member" "logs_daily_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.logs_daily.member
}

resource "google_bigquery_dataset_access" "logs_daily_source_reader" {
  dataset_id    = google_logging_linked_dataset.telemetry.link_id
  role          = "READER"
  user_by_email = google_service_account.logs_daily.email
}

resource "google_bigquery_dataset_access" "logs_daily_writer" {
  dataset_id    = google_bigquery_dataset.logs_daily.dataset_id
  role          = "WRITER"
  user_by_email = google_service_account.logs_daily.email
}

# The Data Transfer Service runs each scheduled query by minting a token for
# its service account, so its service agent needs token creation on that
# account and no other.
resource "google_service_account_iam_member" "logs_daily_transfer_agent" {
  service_account_id = google_service_account.logs_daily.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-bigquerydatatransfer.iam.gserviceaccount.com"
}

# A script with DDL and DML, so no destination table. It runs at 02:00 UTC
# and starts each table from its latest loaded day minus one, so the day the
# previous run loaded in part is reloaded in full.
resource "google_bigquery_data_transfer_config" "logs_daily" {
  display_name         = "${var.namespace}-logs-daily"
  location             = local.bigquery_location
  data_source_id       = "scheduled_query"
  schedule             = "every day 02:00"
  service_account_name = google_service_account.logs_daily.email

  params = {
    query = templatefile("${path.module}/sql/logs_daily.sql", {
      source          = "${var.project_id}.${google_logging_linked_dataset.telemetry.link_id}._AllLogs"
      dataset         = "${var.project_id}.${google_bigquery_dataset.logs_daily.dataset_id}"
      normalise_route = "${var.project_id}.${google_bigquery_dataset.logs_daily.dataset_id}.${google_bigquery_routine.normalise_route.routine_id}"
    })
  }

  depends_on = [
    google_project_iam_member.logs_daily_job_user,
    google_bigquery_dataset_access.logs_daily_source_reader,
    google_bigquery_dataset_access.logs_daily_writer,
    google_service_account_iam_member.logs_daily_transfer_agent,
  ]
}

# Alerting on failed runs. A missed day heals on the next run, but a run that
# keeps failing for longer than var.log_retention_days loses those days for
# good, so a failure has to reach someone.
locals {
  # The config's name is projects/<number>/locations/<location>/transferConfigs/<id>.
  logs_daily_config_id = element(split("/", google_bigquery_data_transfer_config.logs_daily.name), 5)
}

# The Data Transfer Service logs each run's progress against the config, and
# a failed run at ERROR.
resource "google_logging_metric" "logs_daily_failed" {
  name    = "${var.namespace}-logs-daily-failed"
  project = var.project_id
  filter  = <<-EOT
    resource.type="bigquery_dts_config"
    resource.labels.config_id="${local.logs_daily_config_id}"
    severity>=ERROR
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# A new log-based metric takes a few minutes to reach Cloud Monitoring's
# alerting backend, and an alert policy created before then fails with
# "Cannot find metric(s) that match type". depends_on orders the API calls
# only, so this waits out the propagation, as apis/coverage.tf does.
resource "time_sleep" "logs_daily_failed_metric_propagation" {
  depends_on      = [google_logging_metric.logs_daily_failed]
  create_duration = "120s"
}

resource "google_monitoring_alert_policy" "logs_daily_failed" {
  project      = var.project_id
  display_name = "logs_daily scheduled query failed"
  combiner     = "OR"

  depends_on = [time_sleep.logs_daily_failed_metric_propagation]

  conditions {
    display_name = "logs_daily run logged an error"

    condition_threshold {
      filter          = "resource.type=\"bigquery_dts_config\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.logs_daily_failed.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      # ALIGN_SUM, since Cloud Logging writes a zero sample in the interval
      # beside each non-zero one, which ALIGN_COUNT would count as an error.
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  # The service's own run count, which needs no particular log line.
  conditions {
    display_name = "logs_daily run completed as FAILED"

    condition_threshold {
      filter          = "resource.type=\"bigquery_dts_config\" AND resource.labels.config_id=\"${local.logs_daily_config_id}\" AND metric.type=\"bigquerydatatransfer.googleapis.com/transfer_config/completed_runs\" AND metric.labels.completion_state=\"FAILED\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = var.logs_daily_notification_channels

  alert_strategy {
    auto_close = "86400s"
  }
}
