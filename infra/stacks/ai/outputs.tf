output "service_name" {
  description = "Cloud Run service name. dfo-ai's SERVICE_AI in this environment's GitHub Environment."
  value       = module.ai_service.service_name
}

output "service_url" {
  description = "Cloud Run service URL."
  value       = module.ai_service.service_url
}

output "runtime_service_account_email" {
  description = "Email of the dedicated runtime service account the service runs as."
  value       = module.ai_service.runtime_service_account_email
}

output "studio_api_token_secret" {
  description = "Secret Manager id of the studio API token, for granted readers to fetch with gcloud secrets versions access."
  value       = google_secret_manager_secret.studio_api_token.secret_id
}
