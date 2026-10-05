# Values for this environment that the shared stack code in
# infra/stacks/foundation declares with no default.
project_id      = "dev-fin-observatory"
region          = "northamerica-northeast1"
namespace       = "dfo-dev"
github_owner    = "ONEcampaign"
github_owner_id = "6450343"
github_repositories = {
  infra = { name = "dfo-infra", id = "1278400310" }
  ai    = { name = "dfo-ai", id = "1302999900", deploy_environment = "dev", deploy_branch = "dev" }
  apis  = { name = "dfo-apis", id = "1311485891", deploy_environment = "dev", deploy_branch = "dev" }
  dcp   = { name = "dfo-dcp", id = "1279046697", deploy_environment = "dev", deploy_branch = "dev" }
  # dfo-website deploys one environment, staging, from its own staging branch.
  website = { name = "dfo-website", id = "1302999580", deploy_environment = "staging", deploy_branch = "staging" }
  docs    = { name = "dfo-docs", id = "1371825207" }
}
website_deployer_account_id    = "dfo-website-staging-deployer"
website_artifact_repository_id = "dfo-website-staging"
state_bucket                   = "tf-state-dfo-dev-dev-fin-observatory"
applier_impersonators          = ["user:jorge.rivera@one.org"]
# Dev's ingestion operators hold their roles by hand or through owner.
ingestion_operators = []
# Dev's plan.yml runs on pull_request, whose ref is refs/pull/<n>/merge, so the
# planner's binding stays repo-scoped. Dev's apply declares no environment, so
# the applier binds on refs/heads/main alone.
planner_wif_ref         = null
planner_wif_environment = null
applier_wif_environment = null
