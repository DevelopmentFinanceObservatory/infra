# Run records and results pages for the DFO evals. Each eval run writes its
# records under "<suite>/<run_id>/" (manifest.json and results.jsonl, from the
# dfo-evals library), and the evals repository builds one static results page
# from them after each nightly.
#
# The bucket lives here because its first writer is the apis repository's
# nightly eval, and the apis eval accounts live in this stack, so every grant
# names the bucket and the accounts by resource reference.

# Copied from ../foundation's `github_repositories["evals"].id`. The pool's
# attribute condition admits only the ids in that map, so a value here that
# disagrees with it binds a member no token can match.
variable "dfo_evals_repository_id" {
  description = "Immutable numeric GitHub id of DevelopmentFinanceObservatory/evals (GET /repos/DevelopmentFinanceObservatory/evals -> id). Copied from the `foundation` stack's `github_repositories` variable."
  type        = string
  default     = "1469923689"
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

locals {
  # Object names in IAM conditions carry this prefix ahead of the object path.
  eval_runs_object_prefix = "projects/_/buckets/${google_storage_bucket.eval_runs.name}/objects/"
  # The one object the results page publisher may overwrite.
  eval_runs_page_object = "site/index.html"
  # The suite name the apis nightly writes its runs under.
  apis_search_suite = "apis-search"
}

# The evals repository's workflow identity. It reads every run record to build
# the results page and overwrites the page, so it reads the whole bucket and
# writes the page object alone.
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
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.github_wif_pool_id}/attribute.repo_ref/${var.dfo_evals_repository_id}:refs/heads/dev"

  lifecycle {
    # member identifies the binding, so a new repository id replaces it.
    # Creating the new member first keeps the workflow authenticating
    # through the swap.
    create_before_destroy = true
  }
}

resource "google_storage_bucket_iam_member" "evals_runner_eval_runs_viewer" {
  bucket = google_storage_bucket.eval_runs.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.evals_runner.member
}

# Overwriting the page creates the new object and deletes the old one, so the
# account holds objectUser, conditioned on that one object so it cannot alter
# or delete a run record.
resource "google_storage_bucket_iam_member" "evals_runner_eval_runs_page_user" {
  bucket = google_storage_bucket.eval_runs.name
  role   = "roles/storage.objectUser"
  member = google_service_account.evals_runner.member

  condition {
    title       = "results-page-only"
    description = "Only the published results page object"
    expression  = "resource.name == \"${local.eval_runs_object_prefix}${local.eval_runs_page_object}\""
  }
}

# The apis repository's nightly eval identity. It is separate from
# eval_reader.tf's account, which pull request jobs also mint, so a pull
# request cannot write the page or add a run record the page build would
# then read.
resource "google_service_account" "apis_eval_writer" {
  project      = var.project_id
  account_id   = "${var.namespace}-apis-eval-writer"
  display_name = "dfo-apis nightly eval run writer (CI)"
  description  = "Writes the apis nightly eval's run records to the eval runs bucket; holds no project roles"
}

# Only the nightly workflow on the apis repository's default branch may
# impersonate the account. The PR eval gate can also be dispatched on dev,
# so the binding uses the workflow file and ref as well as the repository id.
resource "google_service_account_iam_member" "apis_eval_writer_wif" {
  service_account_id = google_service_account.apis_eval_writer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.github_wif_pool_id}/attribute.repo_workflow_ref/${var.dfo_apis_repository_id}:DevelopmentFinanceObservatory/apis/.github/workflows/eval-nightly.yml@refs/heads/dev"

  lifecycle {
    # A new repository id or workflow ref replaces the member. Creating the
    # new member first keeps the nightly authenticating through the swap.
    create_before_destroy = true
  }
}

# The nightly writes one new run directory per run and never overwrites one
# (dfo-evals refuses to), so create under its own suite's prefix is all it
# needs.
resource "google_storage_bucket_iam_member" "apis_eval_writer_eval_runs_creator" {
  bucket = google_storage_bucket.eval_runs.name
  role   = "roles/storage.objectCreator"
  member = google_service_account.apis_eval_writer.member

  condition {
    title       = "apis-search-runs-only"
    description = "Only run records under the apis-search suite"
    expression  = "resource.name.startsWith(\"${local.eval_runs_object_prefix}${local.apis_search_suite}/\")"
  }
}

output "apis_eval_writer_service_account_email" {
  description = "Email of the apis nightly eval's run writer account. The apis repository's nightly workflow impersonates it through the `foundation` stack's `workload_identity_provider` output."
  value       = google_service_account.apis_eval_writer.email
}

# The people who read run records and results pages come from the
# eval_runs_viewers object of the apis principals secret, keyed by label, so no
# address sits in this repository. The stacks share one schema, so dfo-prod's
# apis secret holds the same key, empty, since prod has no eval runs bucket.
resource "google_storage_bucket_iam_member" "eval_runs_viewers" {
  for_each = toset(nonsensitive(keys(local.principals.eval_runs_viewers)))
  bucket   = google_storage_bucket.eval_runs.name
  role     = "roles/storage.objectViewer"
  member   = local.principals.eval_runs_viewers[each.key]
}
