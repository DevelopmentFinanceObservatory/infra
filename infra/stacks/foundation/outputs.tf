output "project_id" {
  description = "Project ID this environment deploys into. scripts/handoff.sh hands it to every service repo as PROJECT_ID."
  value       = var.project_id
}

output "region" {
  description = "Region of this environment's Artifact Registry repos and Cloud Run services. scripts/handoff.sh hands it to every service repo as REGION."
  value       = var.region
}

output "workload_identity_pool_id" {
  description = "Short workload_identity_pool_id of the shared GitHub Actions WIF pool."
  value       = google_iam_workload_identity_pool.github.workload_identity_pool_id
}

output "workload_identity_provider" {
  description = "Full WIF provider resource name (projects/<number>/locations/global/workloadIdentityPools/<pool>/providers/<provider>). This is the WIF_PROVIDER value handed to dfo-ai, dfo-apis, dfo-dcp, dfo-website, and this repo's own CI."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "planner_service_account" {
  description = "Email of the dfo-infra read-only plan-on-PR service account."
  value       = module.planner.email
}

output "applier_service_account" {
  description = "Email of the dfo-infra apply-on-merge service account."
  value       = module.applier.email
}

output "ai_deployer_service_account" {
  description = "Email of the dfo-ai image-deployer service account. This is dfo-ai's WIF_SA value."
  value       = module.ai_deployer.email
}

output "apis_deployer_service_account" {
  description = "Email of the dfo-apis image-deployer service account. This is dfo-apis' WIF_SA value."
  value       = module.apis_deployer.email
}

output "website_deployer_service_account" {
  description = "Email of the dfo-website image-deployer service account. This is dfo-website's WIF_SA value."
  value       = module.website_deployer.email
}

output "dcp_deployer_service_account" {
  description = "Email of the dfo-dcp image-builder service account. This is dfo-dcp's WIF_SA value — it authenticates dfo-dcp's CI to push images to Artifact Registry, nothing more; it has no Cloud Run access."
  value       = module.dcp_deployer.email
}

output "site_qa_deployer_service_account" {
  description = "Email of the dfo-site-qa Firebase deployer service account, or null in an environment that does not list site_qa. dfo-site-qa's deploy workflow names it."
  value       = one(module.site_qa_deployer[*].email)
}

output "docs_sync_service_account" {
  description = "Email of the dfo-docs Google Docs sync service account. scripts/handoff.sh writes it into dfo-docs' docsync environment as DOCSYNC_SERVICE_ACCOUNT; it holds no project roles, and Drive access comes from its membership of the ONE Data shared drive."
  value       = module.docs_sync.email
}

output "artifact_registry_datacommons_repository_id" {
  description = "Repository ID of the shared `datacommons` Artifact Registry repo (dcp, ai, and apis images push here; dfo-website pushes to its own repo instead)."
  value       = google_artifact_registry_repository.datacommons.repository_id
}

output "artifact_registry_dcp_build_cache_repository_id" {
  description = "Repository ID of the `dfo-dcp-build-cache` Artifact Registry repo (dcp's BuildKit cache manifests; dfo-dcp-deployer is the only writer)."
  value       = google_artifact_registry_repository.dcp_build_cache.repository_id
}

output "artifact_registry_website_repository_id" {
  description = "Repository ID of dfo-website's Artifact Registry repo (its service and migrate job images; the website deployer is the only writer)."
  value       = google_artifact_registry_repository.website.repository_id
}

output "usage_logs_dataset" {
  description = "The usage_logs bucket's linked BigQuery dataset, as project.dataset, or null where usage_logs is unset. Its _AllLogs view holds the usage log lines."
  value       = local.usage_logs_enabled ? "${var.project_id}.${google_logging_linked_dataset.usage_logs[0].link_id}" : null
}
