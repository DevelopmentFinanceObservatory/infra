# The sdk repository's end-to-end workflow identity. The workflow runs the
# Python and TypeScript clients against the dev apis service, which rejects
# anonymous requests, so the jobs call it with an ID token minted as this
# account. It reads no bucket and holds no project role.
#
# The account lives here, beside the service it invokes, so its grants name the
# account and the service by resource reference. The repository's entry in
# ../foundation's `github_repositories` is what admits its tokens to the shared
# pool at all.

# Copied from ../foundation's `github_repositories["sdk"].id`. The pool's
# attribute condition admits only the ids in that map, so a value here that
# disagrees with it binds a member no token can match.
variable "dfo_sdk_repository_id" {
  description = "Immutable numeric GitHub id of DevelopmentFinanceObservatory/sdk (GET /repos/DevelopmentFinanceObservatory/sdk -> id). Copied from the `foundation` stack's `github_repositories` variable."
  type        = string
  default     = "1428553790"
}

resource "google_service_account" "sdk_e2e" {
  project      = var.project_id
  account_id   = "dfo-dev-sdk-e2e"
  display_name = "dfo sdk end-to-end tests (CI)"
  description  = "Calls dfo-dev-apis for the sdk repository's end-to-end workflow; holds no project roles"
}

# Only a run on the sdk repository's default branch may impersonate the
# account, so a pull request or a feature branch cannot mint a token that
# reaches the service. The member keys on `attribute.repo_ref`, which the
# pool's mapping composes from the repository id and the ref, for the reason
# ../foundation/main.tf gives for composing from ids.
resource "google_service_account_iam_member" "sdk_e2e_wif" {
  service_account_id = google_service_account.sdk_e2e.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.github_wif_pool_id}/attribute.repo_ref/${var.dfo_sdk_repository_id}:refs/heads/main"

  lifecycle {
    # member identifies the binding, so a new repository id replaces it.
    # Creating the new member first keeps the workflow authenticating
    # through the swap.
    create_before_destroy = true
  }
}

# The grant names the service and the account by reference, so neither can
# drift from a copied value.
resource "google_cloud_run_v2_service_iam_member" "sdk_e2e_apis_invoker" {
  project  = var.project_id
  location = var.region
  name     = module.apis_service.service_name
  role     = "roles/run.invoker"
  member   = google_service_account.sdk_e2e.member
}

# The workflow reaches the account by WIF impersonation, then mints an ID token
# through the IAM Credentials generateIdToken call. That call needs
# iam.serviceAccounts.getOpenIdToken on the account itself, which an account
# lacks on itself by default.
resource "google_service_account_iam_member" "sdk_e2e_self_id_token" {
  service_account_id = google_service_account.sdk_e2e.name
  role               = "roles/iam.serviceAccountOpenIdTokenCreator"
  member             = google_service_account.sdk_e2e.member
}
