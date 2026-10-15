# The apis repository's search eval job identity. The job stages the coverage index
# and the origin catalogue onto a GitHub runner and starts two local apps
# against them, so it reads both buckets and writes nothing. It also calls the
# dev apis service, so it holds run.invoker there.
#
# The account lives here, beside the buckets, and not in ../foundation with
# the deployers: both stacks apply in parallel on merge, so a foundation
# account would race the bucket bindings below and fail them on a missing
# member.

# Copied from ../foundation's `pool_id` default and its `workload_identity_pool_id`
# output, for the same reason variables.tf gives for the other cross-stack
# values.
variable "github_wif_pool_id" {
  description = "Short workload_identity_pool_id of the shared GitHub Actions WIF pool. Copied from the `foundation` stack's `workload_identity_pool_id` output."
  type        = string
  default     = "github-pool"
}

# Copied from ../foundation's `github_repositories["apis"].id`. The pool's
# attribute condition admits only the ids in that map, so a value here that
# disagrees with it binds a member no token can match.
variable "dfo_apis_repository_id" {
  description = "Immutable numeric GitHub id of DevelopmentFinanceObservatory/apis (GET /repos/DevelopmentFinanceObservatory/apis -> id). Copied from the `foundation` stack's `github_repositories` variable."
  type        = string
  default     = "1401633649"
}

resource "google_service_account" "eval_reader" {
  project      = var.project_id
  account_id   = "dfo-dev-apis-eval-reader"
  display_name = "dfo-apis search eval reader (CI)"
  description  = "Reads the coverage and origin catalogue buckets for dfo-apis's search eval workflows; holds no project roles"
}

# Any workflow run in the apis repository may impersonate the account: pull requests,
# pushes and the nightly schedule all run the eval. The member keys on
# `attribute.repository_id` rather than the name for the reason the pool's
# attribute condition gives in ../foundation/main.tf. Narrowing it to those
# events needs an event attribute the pool's mapping does not carry, and a
# mapping mistake cuts every GitHub run off GCP, which object reads on two
# buckets do not justify.
resource "google_service_account_iam_member" "eval_reader_wif" {
  service_account_id = google_service_account.eval_reader.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.github_wif_pool_id}/attribute.repository_id/${var.dfo_apis_repository_id}"

  lifecycle {
    # member identifies the binding, so a new repository id replaces it.
    # Creating the new member first keeps the eval jobs authenticating
    # through the swap.
    create_before_destroy = true
  }
}

resource "google_storage_bucket_iam_member" "eval_reader_coverage_viewer" {
  bucket = google_storage_bucket.coverage.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.eval_reader.member
}

resource "google_storage_bucket_iam_member" "eval_reader_origin_catalogue_viewer" {
  bucket = google_storage_bucket.origin_catalogue.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.eval_reader.member
}

# The eval jobs call the dev apis service with an ID token minted as this
# account, so it holds run.invoker on that one service. The grant names the
# service and the account by reference, so neither can drift from a copied
# value.
resource "google_cloud_run_v2_service_iam_member" "eval_reader_apis_invoker" {
  project  = var.project_id
  location = var.region
  name     = module.apis_service.service_name
  role     = "roles/run.invoker"
  member   = google_service_account.eval_reader.member
}

# The job's credentials are this account's, reached through WIF
# impersonation, and minting an ID token through the IAM Credentials
# generateIdToken call needs iam.serviceAccounts.getOpenIdToken on the
# account itself, which an account does not hold on itself by default.
resource "google_service_account_iam_member" "eval_reader_self_id_token" {
  service_account_id = google_service_account.eval_reader.name
  role               = "roles/iam.serviceAccountOpenIdTokenCreator"
  member             = google_service_account.eval_reader.member
}

output "eval_reader_service_account_email" {
  description = "Email of the search eval reader account. The apis repository needs two repository secrets, because the eval jobs run on pull requests and cannot read the `dev` environment's WIF_PROVIDER and WIF_SA. EVAL_WIF_SA takes this output. EVAL_WIF_PROVIDER takes the `foundation` stack's `workload_identity_provider` output."
  value       = google_service_account.eval_reader.email
}
