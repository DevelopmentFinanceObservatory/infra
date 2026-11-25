output "landing_bucket_name" {
  description = "Name of the pipelines' landing bucket."
  value       = google_storage_bucket.landing.name
}

output "exports_bucket_name" {
  description = "Name of the pipelines' export bucket."
  value       = google_storage_bucket.exports.name
}

output "bigquery_dataset_ids" {
  description = "IDs of the BigQuery datasets the pipelines load into."
  value       = [for dataset in google_bigquery_dataset.pipelines : dataset.dataset_id]
}
