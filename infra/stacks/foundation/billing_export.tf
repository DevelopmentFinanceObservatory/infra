# The BigQuery dataset that Cloud Billing exports to. Terraform owns the
# dataset only: Google offers no API for the export setting itself, so a
# billing account admin turns the export on in the console once the dataset
# exists (README "Billing export"). Created only when billing_export_dataset_id
# is set. One export covers every project on the billing account, so a single
# environment hosts it.
locals {
  billing_export_enabled = var.billing_export_dataset_id != ""
}

resource "google_project_service" "billing_export_bigquery" {
  count = local.billing_export_enabled ? 1 : 0

  service            = "bigquery.googleapis.com"
  disable_on_destroy = false
}

resource "google_bigquery_dataset" "billing_export" {
  count = local.billing_export_enabled ? 1 : 0

  dataset_id  = var.billing_export_dataset_id
  description = "Cloud Billing export (standard and detailed usage cost), written by billing-export-bigquery@system.gserviceaccount.com."

  # A multi-region location is what makes the first export backfill from the
  # start of the previous month; a single region starts empty. The location
  # cannot change after creation.
  location = "EU"

  # No access blocks and no default table or partition expiration. Turning
  # the export on adds the export service account to the dataset as an owner,
  # and access blocks here would remove it on the next apply. An expiration
  # would delete billing history.

  depends_on = [google_project_service.billing_export_bigquery]
}
