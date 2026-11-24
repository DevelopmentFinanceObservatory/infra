# Run records and results pages for the DFO evals. Each eval run writes its
# records under "<suite>/<run_id>/" (manifest.json and results.jsonl, from the
# dfo-evals library), and the evals repository builds one static results page
# from them after each nightly.
#
# The bucket lives here because its first writers are the apis repository's
# eval jobs, whose account (eval_reader.tf) this stack owns, and so every grant
# names the bucket and the accounts by resource reference.

# Copied from ../foundation's `github_repositories["evals"].id`. The pool's
# attribute condition admits only the ids in that map, so a value here that
# disagrees with it binds a member no token can match.
variable "dfo_evals_repository_id" {
  description = "Immutable numeric GitHub id of DevelopmentFinanceObservatory/evals (GET /repos/DevelopmentFinanceObservatory/evals -> id). Copied from the `foundation` stack's `github_repositories` variable."
  type        = string
  default     = "1469923689"
}

variable "eval_runs_viewers" {
  description = "IAM members, such as group:team@example.org, who read run records and results pages in the eval runs bucket."
  type        = list(string)
  default     = []
}

resource "google_storage_bucket" "eval_runs" {
  name                        = "${var.namespace}-eval-runs-${var.project_id}"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # No lifecycle_rule: run records outlive Langfuse's retention on purpose, and
  # the results page reads every run it shows history for.
}

output "eval_runs_bucket_name" {
  description = "Name of the eval runs bucket. Run records sit under \"<suite>/<run_id>/\"; the results page under \"site/index.html\"."
  value       = google_storage_bucket.eval_runs.name
}

# The evals repository's workflow identity. It reads every run record to build
# the results page and overwrites the page, so it needs read, create and delete
# (an overwrite deletes the old object) on this one bucket, and nothing else.
resource "google_service_account" "evals_runner" {
  project      = var.project_id
  account_id   = "${var.namespace}-evals-runner"
  display_name = "dfo evals results page (CI)"
  description  = "Reads run records and publishes the results page in the eval runs bucket for the evals repository's workflows; holds no project roles"
}

# Only a run on the evals repository's default branch may impersonate the
# account, so a pull request cannot overwrite the published page. The member
# keys on `attribute.repo_ref` for the reason sdk_e2e.tf gives.
resource "google_service_account_iam_member" "evals_runner_wif" {
  service_account_id = google_service_account.evals_runner.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.github_wif_pool_id}/attribute.repo_ref/${var.dfo_evals_repository_id}:refs/heads/main"

  lifecycle {
    # member identifies the binding, so a new repository id replaces it.
    # Creating the new member first keeps the workflow authenticating
    # through the swap.
    create_before_destroy = true
  }
}

resource "google_storage_bucket_iam_member" "evals_runner_eval_runs_user" {
  bucket = google_storage_bucket.eval_runs.name
  role   = "roles/storage.objectUser"
  member = google_service_account.evals_runner.member
}

# The apis repository's eval jobs write one new run directory per run and never
# overwrite one (dfo-evals refuses to), so create is all they need.
resource "google_storage_bucket_iam_member" "eval_reader_eval_runs_creator" {
  bucket = google_storage_bucket.eval_runs.name
  role   = "roles/storage.objectCreator"
  member = google_service_account.eval_reader.member
}

resource "google_storage_bucket_iam_member" "eval_runs_viewers" {
  for_each = toset(var.eval_runs_viewers)
  bucket   = google_storage_bucket.eval_runs.name
  role     = "roles/storage.objectViewer"
  member   = each.value
}
