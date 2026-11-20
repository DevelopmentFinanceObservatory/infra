# The datasets and identities of the DevelopmentFinanceObservatory/analytics
# repository, a dbt project that builds its models from the four source
# datasets below. The metric logic lives in that repository. This stack holds
# only the datasets dbt writes and the grants that let it read and write.
#
# Each dbt target writes one dataset: prod (the scheduled job's service
# account) writes analytics, ci (the CI service account) writes analytics_ci,
# and dev (a developer's own credentials) writes analytics_dev. The CI and
# dev datasets expire their tables, so a model that was renamed or dropped
# leaves nothing behind for long.
locals {
  analytics_datasets = {
    analytics = {
      description   = "Models built by the analytics repository's scheduled dbt run as ${var.namespace}-analytics-runner."
      expiration_ms = null
    }
    analytics_ci = {
      description   = "Models built by the analytics repository's CI as ${var.namespace}-analytics-ci. Tables expire after a day."
      expiration_ms = 24 * 60 * 60 * 1000
    }
    analytics_dev = {
      description   = "Models built by analytics developers with their own credentials. Tables expire after seven days."
      expiration_ms = 7 * 24 * 60 * 60 * 1000
    }
  }

  # The datasets dbt/models/sources.yml in the analytics repository declares.
  # website_export and langfuse_export are created by the website and ai
  # stacks. dfo_logs holds request IPs and user agents, and both accounts and
  # every analytics developer below read it, as README "Logs" lists.
  analytics_source_datasets = [
    google_logging_linked_dataset.telemetry.link_id,
    "website_export",
    "langfuse_export",
    google_bigquery_dataset.logs_daily.dataset_id,
    google_bigquery_dataset.web_history.dataset_id,
  ]

  # The service accounts, each with the one dataset it writes. The
  # runner writes only analytics, so a model the analytics repository places in
  # another dataset with +schema needs a WRITER grant on that dataset here
  # first.
  analytics_accounts = {
    ci = {
      display_name = "${var.namespace} analytics CI"
      description  = "Runs the analytics repository's dbt build in CI: reads the analytics sources, writes analytics_ci."
      dataset      = "analytics_ci"
    }
    runner = {
      display_name = "${var.namespace} analytics dbt run"
      description  = "Runs the analytics repository's scheduled dbt build: reads the analytics sources, writes analytics."
      dataset      = "analytics"
    }
  }

  analytics_account_source_grants = {
    for pair in setproduct(keys(local.analytics_accounts), local.analytics_source_datasets) :
    "${pair[0]} ${pair[1]}" => { account = pair[0], dataset = pair[1] }
  }

  # The developers, from the principals secret's analytics_developers object
  # (main.tf), split by member kind as reporting.tf splits the readers. Each
  # grant is keyed by the developer's label, and the member stays sensitive.
  analytics_developer_principals = {
    for label in nonsensitive(keys(local.principals.analytics_developers)) : label => {
      member  = local.principals.analytics_developers[label]
      kind    = split(":", local.principals.analytics_developers[label])[0]
      address = split(":", local.principals.analytics_developers[label])[1]
    }
  }

  analytics_developer_source_grants = {
    for pair in setproduct(keys(local.analytics_developer_principals), local.analytics_source_datasets) :
    "${pair[0]} ${pair[1]}" => { developer = pair[0], dataset = pair[1] }
  }
}

resource "google_bigquery_dataset" "analytics" {
  for_each = local.analytics_datasets

  dataset_id                  = each.key
  location                    = local.bigquery_location
  description                 = each.value.description
  default_table_expiration_ms = each.value.expiration_ms

  # Every grant on this dataset is a google_bigquery_dataset_access. An access
  # block here would be authoritative and remove them on the next apply.

  depends_on = [google_project_service.apis]
}

# The service accounts hold no keys. CI reaches its account through Workload
# Identity Federation (analytics_ci_wif below), and the runner has no Cloud Run
# job yet.
resource "google_service_account" "analytics" {
  for_each = local.analytics_accounts

  account_id   = "${var.namespace}-analytics-${each.key}"
  display_name = each.value.display_name
  description  = each.value.description
}

resource "google_project_iam_member" "analytics_job_user" {
  for_each = local.analytics_accounts

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.analytics[each.key].member
}

resource "google_bigquery_dataset_access" "analytics_writer" {
  for_each = local.analytics_accounts

  dataset_id    = google_bigquery_dataset.analytics[each.value.dataset].dataset_id
  role          = "WRITER"
  user_by_email = google_service_account.analytics[each.key].email
}

# READER on dfo_logs is all a query of the linked dataset needs, as for
# dfo-prod-logs-daily (logs_daily.tf).
resource "google_bigquery_dataset_access" "analytics_source_reader" {
  for_each = local.analytics_account_source_grants

  dataset_id    = each.value.dataset
  role          = "READER"
  user_by_email = google_service_account.analytics[each.value.account].email
}

# Developers build in analytics_dev with their own credentials, so each gets
# the same reads as the service accounts and writes only there. Their
# roles/bigquery.jobUser is people_job_user in main.tf, shared with the
# readers. analytics_dev is one dataset for every developer, so the last build
# of a model replaces anyone else's.
resource "google_bigquery_dataset_access" "analytics_developers_writer" {
  for_each = local.analytics_developer_principals

  dataset_id     = google_bigquery_dataset.analytics["analytics_dev"].dataset_id
  role           = "WRITER"
  group_by_email = each.value.kind == "group" ? each.value.address : null
  user_by_email  = each.value.kind == "user" ? each.value.address : null
}

resource "google_bigquery_dataset_access" "analytics_developers_source_reader" {
  for_each = local.analytics_developer_source_grants

  dataset_id     = each.value.dataset
  role           = "READER"
  group_by_email = local.analytics_developer_principals[each.value.developer].kind == "group" ? local.analytics_developer_principals[each.value.developer].address : null
  user_by_email  = local.analytics_developer_principals[each.value.developer].kind == "user" ? local.analytics_developer_principals[each.value.developer].address : null
}

# Copied from ../foundation's `pool_id` default and its
# `workload_identity_pool_id` output, as infra/dfo-dev/apis/eval_reader.tf does.
variable "github_wif_pool_id" {
  description = "Short workload_identity_pool_id of the shared GitHub Actions WIF pool. Copied from the `foundation` stack's `workload_identity_pool_id` output."
  type        = string
  default     = "github-pool"
}

# Copied from ../foundation's `github_repositories["analytics"].id`. The pool's
# attribute condition admits only the ids in that map, so a value here that
# disagrees with it binds a member no token can match. Null leaves CI with no
# binding, until both stacks carry its id (README "Analytics repo").
variable "analytics_repository_id" {
  description = "Immutable numeric GitHub id of DevelopmentFinanceObservatory/analytics (GET /repos/DevelopmentFinanceObservatory/analytics -> id). Copied from the `foundation` stack's `github_repositories` variable. Null makes no WIF binding for the CI account."
  type        = string
  default     = null

  validation {
    condition     = var.analytics_repository_id == null || can(regex("^[0-9]+$", var.analytics_repository_id))
    error_message = "analytics_repository_id must be the repository's numeric GitHub id, or null."
  }
}

# Only a run on the analytics repository's main branch may impersonate the CI
# account. The account reads `dfo_logs`, request IPs and user agents included,
# so a pull request or a feature branch must not mint a token for it. The
# repository's dbt-build job queries BigQuery only on pushes to main. The member
# keys on `attribute.repo_ref`, which the pool's mapping composes from the
# repository id and the ref, for the reason ../foundation/main.tf gives for
# composing from ids.
resource "google_service_account_iam_member" "analytics_ci_wif" {
  count = var.analytics_repository_id == null ? 0 : 1

  service_account_id = google_service_account.analytics["ci"].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.github_wif_pool_id}/attribute.repo_ref/${var.analytics_repository_id}:refs/heads/main"

  lifecycle {
    # member identifies the binding, so a new repository id replaces it.
    # Creating the new member first keeps CI authenticating through the swap.
    create_before_destroy = true
  }
}

output "analytics_ci_service_account_email" {
  description = "Email of dfo-prod-analytics-ci, for the analytics repository's GCP_CI_SERVICE_ACCOUNT variable. GCP_WIF_PROVIDER takes the `foundation` stack's `workload_identity_provider` output."
  value       = google_service_account.analytics["ci"].email
}

# The analytics repository's job images. Its deploy workflow pushes one image
# per commit on main, tagged with the commit sha, and only
# dfo-prod-analytics-deployer may write here. The project's Artifact Registry
# API is enabled by the foundation stack. The cleanup policy matches
# ../foundation's `datacommons` repository: a keep rule wins over a delete rule,
# so the ten newest images survive for rollback whatever their age.
resource "google_artifact_registry_repository" "analytics" {
  location      = var.region
  repository_id = "analytics"
  format        = "DOCKER"
  description   = "Job images of the analytics repository, writable by ${var.namespace}-analytics-deployer only"

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-stale"
    action = "DELETE"
    condition {
      older_than = "2592000s"
      tag_state  = "TAGGED"
    }
  }
}

resource "google_service_account" "analytics_deployer" {
  account_id   = "${var.namespace}-analytics-deployer"
  display_name = "${var.namespace} analytics image deployer"
  description  = "Pushes the analytics repository's job images from its main branch. Writes the analytics Artifact Registry repository and nothing else."
}

resource "google_artifact_registry_repository_iam_member" "analytics_deployer_writer" {
  project    = google_artifact_registry_repository.analytics.project
  location   = google_artifact_registry_repository.analytics.location
  repository = google_artifact_registry_repository.analytics.repository_id
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.analytics_deployer.member
}

# The GitHub Environment and git ref the deployer's binding admits. The
# analytics repository's deploy workflow declares this Environment on its push
# from main, and the Environment's deployment branch policy there admits main
# alone.
locals {
  analytics_deploy_environment = "production"
  analytics_deploy_ref         = "refs/heads/main"
}

# Only a job on main that declares the production Environment may impersonate
# the deployer, as for dfo-ai-deployer (../foundation's `ai_deployer`): the
# member keys on `attribute.repo_env_ref`, which the pool maps to
# <repository_id>:<environment>:<ref>. A pull request run carries neither
# claim, so it cannot push an image the scheduled jobs would then run. Null
# analytics_repository_id makes no binding.
resource "google_service_account_iam_member" "analytics_deployer_wif" {
  count = var.analytics_repository_id == null ? 0 : 1

  service_account_id = google_service_account.analytics_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.github_wif_pool_id}/attribute.repo_env_ref/${var.analytics_repository_id}:${local.analytics_deploy_environment}:${local.analytics_deploy_ref}"

  lifecycle {
    # member identifies the binding, so a new repository id replaces it.
    # Creating the new member first keeps deploys authenticating through the
    # swap.
    create_before_destroy = true
  }
}

output "analytics_deployer_service_account_email" {
  description = "Email of dfo-prod-analytics-deployer, for the analytics repository's GCP_DEPLOY_SERVICE_ACCOUNT variable."
  value       = google_service_account.analytics_deployer.email
}

output "analytics_image_repository" {
  description = "Docker path of the analytics Artifact Registry repository, which the analytics repository's deploy workflow pushes to."
  value       = "${google_artifact_registry_repository.analytics.location}-docker.pkg.dev/${google_artifact_registry_repository.analytics.project}/${google_artifact_registry_repository.analytics.repository_id}"
}
