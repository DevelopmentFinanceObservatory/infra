# dfo-apis keys every graph-derived cache on the DC service's serving
# revision, which changes after each ingestion, and clears its caches when
# the revision moves. The runtime service account reads that revision through
# the Cloud Run Admin API (`GET .../services/<name>`), which needs
# `roles/run.viewer` on the service. The grant covers the DC service only,
# and the account only reads the service's metadata.
resource "google_cloud_run_v2_service_iam_member" "graph_generation_dc_viewer" {
  project  = var.project_id
  location = var.region
  name     = var.datacommons_service_name
  role     = "roles/run.viewer"
  member   = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}
