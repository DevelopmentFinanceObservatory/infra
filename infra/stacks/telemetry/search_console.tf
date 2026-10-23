# Search Console's bulk data export writes into this dataset once a property
# owner turns it on in Search Console (README "After the first apply"). The
# export creates and fills its own tables and sets their partition
# expiration, so the dataset sets none.
resource "google_bigquery_dataset" "searchconsole" {
  dataset_id  = "searchconsole"
  location    = local.bigquery_location
  description = "Search Console bulk data export for developmentfinance.org, written by ${var.search_console_export_account}."

  depends_on = [google_project_service.apis]
}

resource "google_bigquery_dataset_access" "searchconsole_export_writer" {
  dataset_id    = google_bigquery_dataset.searchconsole.dataset_id
  role          = "WRITER"
  user_by_email = var.search_console_export_account
}

resource "google_project_iam_member" "searchconsole_export_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${var.search_console_export_account}"
}
