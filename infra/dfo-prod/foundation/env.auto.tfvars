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
  dcp     = { name = "dcp", id = "1401633556", deploy_environment = "production", deploy_branch = "main" }
  website = { name = "website", id = "1401633828", deploy_environment = "production", deploy_branch = "main" }
  docs    = { name = "docs", id = "1401634043" }
}
website_deployer_account_id    = "dfo-website-deployer"
website_artifact_repository_id = "dfo-website"
state_bucket                   = "tf-state-dfo-prod-prod-fin-observatory"

# plan-prod.yml's plan job runs PR code on pull_request_target, whose ref is
# refs/heads/main, the applier's ref. The planner binds to the `plan`
# environment on main and the applier to `production` on main, so that job's
# token matches only the planner, and a pull_request workflow a PR adds,
# whose ref is refs/pull/<n>/merge, matches neither.
planner_wif_ref         = "refs/heads/main"
planner_wif_environment = "plan"
applier_wif_environment = "production"

# Placeholder: list the project owners who may impersonate the applier, as
# "user:<email>". Empty grants no one.
applier_impersonators = []

# Placeholder: the operators who run Dagster ingestion into prod, as
# "user:<email>". Leave empty until dcp has applied and the four names below
# are set.
ingestion_operators = []
# ingestion_workflow_service_account_email = "" # from dcp output ingestion_workflow_service_account_email after apply
# ingestion_artifacts_bucket_name          = "" # from dcp output storage_artifacts_bucket_name after apply
# ingestion_spanner_instance_id            = "" # from dcp output spanner_instance_id after apply
# ingestion_spanner_database_id            = "" # from dcp output spanner_database_id after apply
