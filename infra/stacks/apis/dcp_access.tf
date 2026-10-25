# The Data Commons service drops its allUsers invoker grant, so every identity
# in this stack that calls it needs `roles/run.invoker` on it. The grants sit
# here, beside the identities, as graph_generation_access.tf does for
# `roles/run.viewer`. They name the DC service through
# `var.datacommons_service_name` and each account by reference. The dev eval
# reader's grant sits in `dfo-dev/apis/eval_reader.tf`, beside the account.
resource "google_cloud_run_v2_service_iam_member" "dc_invoker_apis" {
  project  = var.project_id
  location = var.region
  name     = var.datacommons_service_name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}

resource "google_cloud_run_v2_service_iam_member" "dc_invoker_datasets_worker" {
  project  = var.project_id
  location = var.region
  name     = var.datacommons_service_name
  role     = "roles/run.invoker"
  member   = google_service_account.datasets_worker.member
}

resource "google_cloud_run_v2_service_iam_member" "dc_invoker_origin_catalogue_job" {
  project  = var.project_id
  location = var.region
  name     = var.datacommons_service_name
  role     = "roles/run.invoker"
  member   = google_service_account.origin_catalogue_job.member
}

resource "google_cloud_run_v2_service_iam_member" "dc_invoker_graph_release_job" {
  project  = var.project_id
  location = var.region
  name     = var.datacommons_service_name
  role     = "roles/run.invoker"
  member   = google_service_account.graph_release_job.member
}

resource "google_cloud_run_v2_service_iam_member" "dc_invoker_search_catalogue_job" {
  project  = var.project_id
  location = var.region
  name     = var.datacommons_service_name
  role     = "roles/run.invoker"
  member   = google_service_account.search_catalogue_job.member
}
