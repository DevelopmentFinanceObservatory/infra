# Daily GA4 and Search Console history for the days before each product's
# BigQuery export starts, since neither export backfills.
# scripts/load-ga4-history.sh and scripts/load-search-console-history.sh read
# the two products' APIs as the service account below and write day-partitioned
# tables here, creating each table with its schema on first load. The README's
# "Web history before the exports" lists the grants they need in GA4 and
# Search Console.
resource "google_project_service" "web_history_apis" {
  for_each = toset([
    "analyticsdata.googleapis.com",
    "searchconsole.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

resource "google_bigquery_dataset" "web_history" {
  dataset_id  = "web_history"
  location    = local.bigquery_location
  description = "GA4 and Search Console daily history from their APIs, for the days before each BigQuery export starts. Written by ${google_service_account.web_history.email}."

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "web_history" {
  account_id   = "${var.namespace}-web-history"
  display_name = "${var.namespace} web history loaders"
  description  = "Runs the GA4 and Search Console history loaders: reads both APIs, writes web_history."
}

resource "google_project_iam_member" "web_history_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.web_history.member
}

resource "google_bigquery_dataset_access" "web_history_writer" {
  dataset_id    = google_bigquery_dataset.web_history.dataset_id
  role          = "WRITER"
  user_by_email = google_service_account.web_history.email
}
