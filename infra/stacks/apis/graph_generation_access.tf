# dfo-apis keys every graph-derived cache on the DC service's serving
# revision, which changes after each ingestion, and clears its caches when
# the revision moves. The runtime service accounts of the apis service and the
# datasets worker read that revision through the Cloud Run Admin API
# (`GET .../services/<name>`), which needs `roles/run.viewer` on the service.
# The grants cover the DC service only, and the accounts only read the
# service's metadata. The datasets-maintenance Job reads no graph generation.
resource "google_cloud_run_v2_service_iam_member" "graph_generation_dc_viewer" {
  project  = var.project_id
  location = var.region
  name     = var.datacommons_service_name
  role     = "roles/run.viewer"
  member   = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}

resource "google_cloud_run_v2_service_iam_member" "graph_generation_dc_viewer_worker" {
  project  = var.project_id
  location = var.region
  name     = var.datacommons_service_name
  role     = "roles/run.viewer"
  member   = google_service_account.datasets_worker.member
}
