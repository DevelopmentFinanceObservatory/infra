# shellcheck shell=bash
# The one table of facts about each deploy target, shared by
# scripts/handoff.sh (which writes them onto GitHub) and
# scripts/check-deploy-branch-policy.sh (which audits them), so the two cannot
# disagree. scripts/setup-github-apps.sh reads org_repos and org_repo for
# the repo names in each GitHub org. Both take an environment, `dfo-dev` or `dfo-prod`, and this file
# derives everything else from it: the GitHub org and repo, the GitHub
# Environment name, the deploy branch, and the Terraform root. It also holds
# deploy_values, the map from each GitHub variable and secret a service
# repo's workflows read to the Terraform output that supplies it. Branches
# are pinned here rather than read from GitHub's default_branch, or a
# repo-settings rename could move which branch mints the WIF-trusted
# deployer identity with nothing here reporting it.
#
# The branches mirror the deploy_branch fields of var.github_repositories in
# each environment's foundation stack (infra/<env>/foundation/env.auto.tfvars),
# which compose the ref half of each deployer's WIF binding. That binding is
# what actually enforces the boundary; the deployment branch policy is a
# second line in front of it, and the two disagreeing fails the next deploy
# at the auth step.
#
# Sourced by handoff.sh and check-deploy-branch-policy.sh; targets bash 3.2
# (macOS's shipped bash), hence case statements instead of associative arrays.
#
# Per environment:
#   dfo-dev   ONEcampaign/dfo-<stack>, GitHub Environment `dev`, branch `dev`.
#             dfo-website deploys only its `staging` environment, from the
#             `staging` branch.
#   dfo-prod  DevelopmentFinanceObservatory/<stack> (no `dfo-` prefix),
#             GitHub Environment `production`, branch `main`.

# The stacks that deploy to a service repo in <env>, space-separated on
# stdout. Returns 1, printing nothing, for an unknown environment.
deploy_stacks() {
    case "$1" in
    dfo-dev | dfo-prod) printf '%s' "ai apis dcp website" ;;
    *) return 1 ;;
    esac
}

# The ten repos each environment's GitHub org holds, by short name,
# space-separated on stdout. Returns 1, printing nothing, for an unknown
# environment.
org_repos() {
    case "$1" in
    dfo-dev | dfo-prod) printf '%s' "infra dcp apis ai website pipelines docs ontology spec-kit skills" ;;
    *) return 1 ;;
    esac
}

# org_repo <env> <name> prints <owner>/<repo> for a short name from
# org_repos: ONEcampaign/dfo-<name> in dfo-dev and
# DevelopmentFinanceObservatory/<name> in dfo-prod. Returns 1, printing
# nothing, for an unknown environment or name.
org_repo() {
    local known
    known="$(org_repos "${1:-}")" || return 1
    case " $known " in
    *" ${2:-} "*) ;;
    *) return 1 ;;
    esac
    case "$1" in
    dfo-dev) printf 'ONEcampaign/dfo-%s' "$2" ;;
    dfo-prod) printf 'DevelopmentFinanceObservatory/%s' "$2" ;;
    esac
}

# Terraform root for <stack> in <env>, relative to the repository root.
deploy_tf_dir() {
    printf '%s' "infra/$1/$2"
}

# load_deploy_target <env> <stack> sets, in the caller's shell:
#   DEPLOY_REPO           <owner>/<name> of the service repo
#   DEPLOY_GH_ENV         GitHub Environment the deploy job runs in
#   DEPLOY_BRANCH         the one branch allowed to deploy to it
# Returns 1 with a message on stderr for an unknown environment, or a stack
# that does not deploy to a service repo in that environment, and leaves the
# variables empty.
# shellcheck disable=SC2034 # the DEPLOY_* outputs are read by the sourcing script
load_deploy_target() {
    local env="${1:-}" stack="${2:-}" stacks s known=false
    DEPLOY_REPO="" DEPLOY_GH_ENV="" DEPLOY_BRANCH=""

    if ! stacks="$(deploy_stacks "$env")"; then
        echo "ERROR: unknown environment '$env' (expected dfo-dev or dfo-prod)." >&2
        return 1
    fi
    for s in $stacks; do
        if [ "$s" = "$stack" ]; then known=true; fi
    done
    if [ "$known" != true ]; then
        echo "ERROR: stack '$stack' is not a deploy target in $env (known: $stacks); see scripts/deploy-targets.sh." >&2
        return 1
    fi

    case "$env" in
    dfo-dev)
        DEPLOY_REPO="$(org_repo "$env" "$stack")"
        DEPLOY_GH_ENV=dev
        DEPLOY_BRANCH=dev
        if [ "$stack" = website ]; then
            DEPLOY_GH_ENV=staging
            DEPLOY_BRANCH=staging
        fi
        ;;
    dfo-prod)
        DEPLOY_REPO="$(org_repo "$env" "$stack")"
        DEPLOY_GH_ENV=production
        DEPLOY_BRANCH=main
        ;;
    esac
}

# load_handoff_target <env> <stack> sets the same DEPLOY_* variables as
# load_deploy_target for every stack it accepts, and also accepts `infra`:
# this repo's own plan and apply workflows, which read their values at repo
# level. For infra it sets DEPLOY_REPO to the env's infra repo and leaves
# DEPLOY_GH_ENV and DEPLOY_BRANCH empty, which tells handoff.sh to write
# repo-level variables and set no branch policy. The WIF bindings already pin
# the planner to environment `plan` and the applier to `production` on
# refs/heads/main, and the values are not secret. Fails as load_deploy_target
# does for anything else.
# shellcheck disable=SC2034 # the DEPLOY_* outputs are read by the sourcing script
load_handoff_target() {
    if [ "${2:-}" = infra ] && org_repos "${1:-}" >/dev/null; then
        DEPLOY_REPO="$(org_repo "$1" infra)" DEPLOY_GH_ENV="" DEPLOY_BRANCH=""
        return 0
    fi
    load_deploy_target "$@"
}

# deploy_values <stack> prints, one per line, every GitHub variable and
# secret <stack>'s workflows read, as
#   <var|secret> <NAME> <root> <output>
# where <root> is the stack whose Terraform root holds <output> in the same
# environment. A service stack's workflows read these from their GitHub
# Environment; infra's read them at repo level (see load_handoff_target).
# Names and outputs are the same in dfo-dev and dfo-prod, so the table takes
# no environment. Returns 1, printing nothing, for any other stack.
#
# REGION and PROJECT_ID come from foundation, which owns the Artifact
# Registry repos the image path names, so the image path and AR_REPO cannot
# disagree. DFO_APIS_BASE_URL is baked into the dcp image at build time, so
# the dcp handoff needs the apis stack applied first.
deploy_values() {
    local common
    common="var REGION foundation region
var PROJECT_ID foundation project_id
secret WIF_PROVIDER foundation workload_identity_provider
secret WIF_SA foundation ${1:-}_deployer_service_account"
    case "${1:-}" in
    infra)
        printf '%s\n' \
            "var WIF_PROVIDER foundation workload_identity_provider" \
            "var WIF_PLAN_SA foundation planner_service_account" \
            "var WIF_APPLY_SA foundation applier_service_account"
        ;;
    ai)
        printf '%s\n' "$common" \
            "var AR_REPO foundation artifact_registry_datacommons_repository_id" \
            "var SERVICE_AI ai service_name"
        ;;
    apis)
        printf '%s\n' "$common" \
            "var AR_REPO foundation artifact_registry_datacommons_repository_id" \
            "var SERVICE_APIS apis service_name" \
            "var SERVICE_WORKER apis datasets_worker_service_name" \
            "var JOB_DATASETS_MIGRATE apis datasets_migrate_job_name" \
            "var JOB_PRESENTATION_MIGRATE apis presentation_migrate_job_name" \
            "var JOB_COVERAGE apis coverage_job_name" \
            "var JOB_ORIGIN_CATALOGUE apis origin_catalogue_job_name" \
            "var JOB_SEARCH_CATALOGUE apis search_catalogue_job_name"
        ;;
    dcp)
        printf '%s\n' "$common" \
            "var AR_REPO foundation artifact_registry_datacommons_repository_id" \
            "var AR_CACHE_REPO foundation artifact_registry_dcp_build_cache_repository_id" \
            "var DFO_APIS_BASE_URL apis service_url"
        ;;
    website)
        printf '%s\n' "$common" \
            "var AR_REPO foundation artifact_registry_website_repository_id" \
            "var SERVICE_WEBSITE website service_name" \
            "var MIGRATE_JOB_WEBSITE website migrate_job_name"
        ;;
    *) return 1 ;;
    esac
}
