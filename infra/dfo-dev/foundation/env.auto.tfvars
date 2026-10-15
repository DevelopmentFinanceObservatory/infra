# Values for this environment that the shared stack code in
# infra/stacks/foundation declares with no default.
project_id      = "dev-fin-observatory"
region          = "northamerica-northeast1"
namespace       = "dfo-dev"
github_owner    = "DevelopmentFinanceObservatory"
github_owner_id = "305725777"
github_repositories = {
  infra   = { name = "infra", id = "1401633456" }
  ai      = { name = "ai", id = "1401633727", deploy_environment = "dev", deploy_branch = "dev" }
  apis    = { name = "apis", id = "1401633649", deploy_environment = "dev", deploy_branch = "dev" }
  dcp     = { name = "dcp", id = "1401633556", deploy_environment = "dev", deploy_branch = "dev" }
  website = { name = "website", id = "1401633828", deploy_environment = "dev", deploy_branch = "dev" }
  docs    = { name = "docs", id = "1401634043", deploy_environment = "docsync", deploy_branch = "dev" }
  # dfo-site-qa stays private in ONEcampaign, so its entry names that owner.
  site_qa = { name = "dfo-site-qa", id = "1406139622", owner = { name = "ONEcampaign", id = "6450343" } }
}
website_deployer_account_id    = "dfo-website-staging-deployer"
website_artifact_repository_id = "dfo-website-staging"
state_bucket                   = "tf-state-dfo-dev-dev-fin-observatory"
applier_impersonators          = ["user:jorge.rivera@one.org"]
# Dev's ingestion operators hold their roles by hand or through owner.
ingestion_operators = []
# Dev's plan.yml runs on pull_request, whose ref is refs/pull/<n>/merge, so the
# planner's binding stays repo-scoped. The applier binds to the `dev`
# environment on refs/heads/dev, which apply-stack.yml declares for dfo-dev.
planner_wif_ref         = null
planner_wif_environment = null
applier_wif_ref         = "refs/heads/dev"
applier_wif_environment = "dev"
