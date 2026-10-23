# Values for this environment that the shared stack code in
# infra/stacks/foundation declares with no default.
project_id      = "prod-fin-observatory"
region          = "europe-west1"
namespace       = "dfo-prod"
github_owner    = "DevelopmentFinanceObservatory"
github_owner_id = "305725777"
github_repositories = {
  infra   = { name = "infra", id = "1401633456" }
  ai      = { name = "ai", id = "1401633727", deploy_environment = "production", deploy_branch = "main" }
  apis    = { name = "apis", id = "1401633649", deploy_environment = "production", deploy_branch = "main" }
  dcp     = { name = "dcp", id = "1431071058", deploy_environment = "production", deploy_branch = "main" }
  website = { name = "website", id = "1401633828", deploy_environment = "production", deploy_branch = "main" }
  docs    = { name = "docs", id = "1401634043", deploy_branch = "main" }
}
website_deployer_account_id    = "dfo-website-deployer"
website_artifact_repository_id = "dfo-website"
state_bucket                   = "tf-state-dfo-prod-prod-fin-observatory"

# Hosts the Cloud Billing export for the billing account that pays for dev,
# prod and the Gemini key projects.
billing_export_dataset_id = "billing_export"

# plan-prod.yml's plan job runs PR code on pull_request_target, whose ref is
# refs/heads/main, the applier's ref. The planner binds to the `plan`
# environment on main and the applier to `production` on main, so that job's
# token matches only the planner, and a pull_request workflow a PR adds,
# whose ref is refs/pull/<n>/merge, matches neither.
planner_wif_ref         = "refs/heads/main"
planner_wif_environment = "plan"
applier_wif_ref         = "refs/heads/main"
applier_wif_environment = "production"

# Placeholder: list the project owners who may impersonate the applier, as
# "user:<email>". Empty grants no one.
applier_impersonators = []

# The Google group whose members run Dagster ingestion into prod. Membership
# lives in ONE's Workspace. The four names below are dcp's outputs of the same
# names.
ingestion_operators                      = ["group:dfo-prod-ingestion@one.org"]
ingestion_workflow_service_account_email = "dfo-prod-dc-ing-wf-sa@prod-fin-observatory.iam.gserviceaccount.com"
ingestion_artifacts_bucket_name          = "dfo-prod-dc-artifacts-prod-fin-observatory"
ingestion_spanner_instance_id            = "dfo-prod-dc-instance"
ingestion_spanner_database_id            = "dfo-prod-dc-db"
