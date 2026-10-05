output "raw_bucket_name" {
  description = "Name of the raw landing bucket."
  value       = google_storage_bucket.raw.name
}

output "processed_bucket_name" {
  description = "Name of the processed output bucket."
  value       = google_storage_bucket.processed.name
}

output "bigquery_dataset_ids" {
  description = "IDs of the BigQuery datasets the pipelines load into."
  value       = [for dataset in google_bigquery_dataset.pipelines : dataset.dataset_id]
}
