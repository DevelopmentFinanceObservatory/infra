output "service_name" {
  description = "Cloud Run service name."
  value       = google_cloud_run_v2_service.this.name
}

output "service_url" {
  description = "Cloud Run service URL."
  value       = google_cloud_run_v2_service.this.uri
}

output "runtime_service_account_email" {
  description = "Email of the dedicated runtime service account the service runs as."
  value       = google_service_account.runtime.email
}

output "image" {
  description = "Container image Cloud Run currently reports running. lifecycle.ignore_changes on the resource's own image argument (main.tf) only blocks Terraform from planning a change to it; a refresh still updates this from the live service, so callers bootstrapping a sibling resource that needs an image guaranteed to exist in Artifact Registry can read this instead of embedding a literal tag."
  value       = google_cloud_run_v2_service.this.template[0].containers[0].image
}
