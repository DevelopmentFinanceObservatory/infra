output "reporting_dataset" {
  description = "Fully qualified id of the dataset the team dashboard reads."
  value       = "${var.project_id}.${google_bigquery_dataset.reporting.dataset_id}"
}

output "logs_daily_dataset" {
  description = "Fully qualified id of the daily Cloud Run log aggregates."
  value       = "${var.project_id}.${google_bigquery_dataset.logs_daily.dataset_id}"
}

output "logs_linked_dataset" {
  description = "Fully qualified id of the Log Analytics linked dataset over the telemetry log bucket."
  value       = "${var.project_id}.${google_logging_linked_dataset.telemetry.link_id}"
}

output "searchconsole_dataset" {
  description = "Dataset id to enter in Search Console's bulk data export settings."
  value       = google_bigquery_dataset.searchconsole.dataset_id
}

output "logs_daily_service_account" {
  description = "Service account the logs_daily scheduled query runs as."
  value       = google_service_account.logs_daily.email
}
