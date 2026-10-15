# scripts/handoff.sh reads service_name, migrate_job_name and website_url.
output "service_name" {
  description = "Cloud Run service name. dfo-website's SERVICE_WEBSITE in this environment's GitHub Environment."
  value       = module.website_service.service_name
}

output "migrate_job_name" {
  description = "Cloud Run Job that applies the website's schema migrations. dfo-website's MIGRATE_JOB_WEBSITE in this environment's GitHub Environment."
  value       = google_cloud_run_v2_job.website_migrate.name
}

output "service_url" {
  description = "Cloud Run URL of the website service."
  value       = module.website_service.service_url
}

output "website_url" {
  description = "The website's public origin: the staging service's run.app URL in dfo-dev, https://developmentfinance.org in dfo-prod. scripts/handoff.sh hands it to dcp as DFO_SITE_ORIGIN."
  value       = var.website_url
}

output "runtime_service_account" {
  description = "Email of the website service's runtime service account."
  value       = module.website_service.runtime_service_account_email
}

# Connection details for the app team. The host is the PSC DNS name from variables.tf, resolving to the endpoint below only from inside this stack's VPC, which is why the service carries vpc_access.
output "database_host" {
  description = "DNS name the service connects to Postgres at, resolvable only through this stack's private zone."
  value       = var.platform_dns_name
}

output "database_endpoint_ip" {
  description = "Reserved internal IP behind database_host, for debugging name resolution."
  value       = module.psc_network.endpoint_ip_address
}

output "database_name" {
  description = "The website service's database on the shared instance."
  value       = google_sql_database.website.name
}

output "database_runtime_user" {
  description = "IAM database user the service connects as."
  value       = google_sql_user.website_runtime.name
}

output "migrator_service_account" {
  description = "Email of the website migrator's service account. The migration Job runs as this account."
  value       = google_service_account.website_migrator.email
}

output "migrator_database_user" {
  description = "IAM database user the migrator connects as. Holds CONNECT, CREATE ON DATABASE and CREATE ON SCHEMA public on the website database only. Nothing further is granted here, migrations issue the rest."
  value       = google_sql_user.website_migrator.name
}
