# shellcheck shell=bash
# The one table of facts about the DevelopmentFinanceObservatory repos and
# their GitHub Environments, shared by every script that writes or audits
# GitHub settings, so they cannot disagree:
#   scripts/setup-github-repos.sh         creates each environment with its
#                                         branch policy and reviewers
#   scripts/handoff.sh                    writes Terraform outputs into them
#   scripts/setup-github-apps.sh          writes App credentials into them
#   scripts/check-deploy-branch-policy.sh audits the deploy environments
#
# dfo-dev and dfo-prod deploy from the same repos: dfo-dev from each repo's
# `dev` branch through GitHub Environment `dev`, dfo-prod from `main`
# through `production`. Branches are pinned here rather than read from
# GitHub's default_branch, or a repo-settings change could move which
# branch mints the WIF-trusted deployer identity with nothing here
# reporting it.
#
# The branches mirror the deploy_branch fields of var.github_repositories in
# each environment's foundation stack (infra/<env>/foundation/env.auto.tfvars),
# which compose the ref half of each deployer's WIF binding. That binding
# enforces the boundary; the deployment branch policy is a second line in
# front of it, and the two disagreeing fails the next deploy at the auth
# step.
#
# Sourced by other scripts. It targets bash 3.2 (macOS's shipped bash), hence
# case statements and string tables instead of associative arrays.

GITHUB_OWNER=DevelopmentFinanceObservatory

# Every GitHub Environment the repos hold, one per line:
#   <repo> <environment> <branch> <reviewers>
# <branch> is the one branch the environment admits, or `-` for no branch
# policy. <reviewers> is the org team whose approval a job in the
# environment waits for, or `-` for none.
#
# infra's four environments are the contract its workflows code to. infra
# holds no repo-level WIF values, so a job that declares no environment
# cannot authenticate:
#   dev-plan    dev WIF_PROVIDER and WIF_PLAN_SA. No branch policy, since
#               plan.yml runs on pull_request, whose refs/pull/<n>/merge ref
#               any branch policy refuses.
#   dev         dev WIF_PROVIDER and WIF_APPLY_SA, for apply.yml on dev.
#   plan        prod WIF_PROVIDER, WIF_PLAN_SA and CLOUDFLARE_API_TOKEN, for
#               plan-prod.yml's plan job.
#   production  prod WIF_PROVIDER, WIF_APPLY_SA and CLOUDFLARE_API_TOKEN,
#               for apply.yml on main.
# Each service repo deploys through `dev` and `production`. dcp's `dev`
# also holds the dfo-pin App key and its `production` the dfo-release key.
# docs' `docsync` holds the dfo-docsync App key.
REPO_ENVIRONMENTS="
infra    dev-plan    -     -
infra    dev         dev   -
infra    plan        main  release
infra    production  main  release
ai       dev         dev   -
ai       production  main  release
apis     dev         dev   -
apis     production  main  release
dcp      dev         dev   -
dcp      production  main  release
website  dev         dev   -
website  production  main  release
docs     docsync     dev   -
"

# org_repos prints the ten repos' short names, space-separated.
org_repos() {
    printf '%s' "infra dcp apis ai website pipelines docs ontology spec-kit skills"
}

# org_repo <name> prints <owner>/<name> for a short name from org_repos.
# Returns 1, printing nothing, for any other name.
org_repo() {
    case " $(org_repos) " in
    *" ${1:-} "*) [ -n "${1:-}" ] && printf '%s/%s' "$GITHUB_OWNER" "$1" ;;
    *) return 1 ;;
    esac
}

# default_branch <name> prints the repo's default branch: `main` for infra,
# whose plan-prod.yml runs on pull_request_target and so always loads from
# the default branch, and `dev` everywhere else, so workflow_run and
# scheduled workflows run the code dfo-dev runs.
default_branch() {
    org_repo "${1:-}" >/dev/null || return 1
    case "$1" in
    infra) printf 'main' ;;
    *) printf 'dev' ;;
    esac
}

# repo_environments <name> prints the repo's rows of REPO_ENVIRONMENTS as
# `<environment> <branch> <reviewers>` lines. A repo with no environment
# prints nothing. An unknown repo returns 1.
repo_environments() {
    org_repo "${1:-}" >/dev/null || return 1
    printf '%s\n' "$REPO_ENVIRONMENTS" | awk -v r="$1" '$1 == r { print $2, $3, $4 }'
}

# environment_branch <name> <environment> prints the branch the environment
# admits, or `-`. Returns 1, printing nothing, for an environment the table
# does not list.
environment_branch() {
    local branch
    branch="$(repo_environments "${1:-}" | awk -v e="${2:-}" '$1 == e { print $2 }')" || return 1
    [ -n "$branch" ] || return 1
    printf '%s' "$branch"
}

# deploy_environment <env> prints the GitHub Environment a Terraform
# environment's deploy and apply jobs run in. Returns 1 for an unknown one.
deploy_environment() {
    case "${1:-}" in
    dfo-dev) printf 'dev' ;;
    dfo-prod) printf 'production' ;;
    *) return 1 ;;
    esac
}

# plan_environment <env> prints the infra environment a Terraform
# environment's planner runs in. Returns 1 for an unknown one.
plan_environment() {
    case "${1:-}" in
    dfo-dev) printf 'dev-plan' ;;
    dfo-prod) printf 'plan' ;;
    *) return 1 ;;
    esac
}

# The stacks that deploy to a service repo in <env>, space-separated on
# stdout. Returns 1, printing nothing, for an unknown environment.
deploy_stacks() {
    case "${1:-}" in
    dfo-dev | dfo-prod) printf '%s' "ai apis dcp website" ;;
    *) return 1 ;;
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
    local env="${1:-}" stack="${2:-}" stacks gh_env branch
    DEPLOY_REPO="" DEPLOY_GH_ENV="" DEPLOY_BRANCH=""

    if ! stacks="$(deploy_stacks "$env")"; then
        echo "ERROR: unknown environment '$env' (expected dfo-dev or dfo-prod)." >&2
        return 1
    fi
    case " $stacks " in
    *" $stack "*) [ -n "$stack" ] ;;
    *) false ;;
    esac || {
        echo "ERROR: stack '$stack' is not a deploy target in $env (known: $stacks); see scripts/deploy-targets.sh." >&2
        return 1
    }
    gh_env="$(deploy_environment "$env")"
    branch="$(environment_branch "$stack" "$gh_env")" || {
        echo "ERROR: REPO_ENVIRONMENTS lists no '$gh_env' environment for $stack." >&2
        return 1
    }
    DEPLOY_REPO="$(org_repo "$stack")"
    DEPLOY_GH_ENV="$gh_env"
    DEPLOY_BRANCH="$branch"
}

# handoff_targets <env> <stack> prints, one per line, where scripts/handoff.sh
# writes <stack>'s values in <env>:
#   <owner>/<repo> <environment> <branch> <values>
# <values> is the deploy_values key for that environment. A service stack
# has one line, its deploy environment. infra has two: the planner's
# environment with infra-plan and the applier's with infra-apply. docs has
# one, in dfo-dev only: its `docsync` environment with docs-sync, since
# docsync.yml authenticates to dfo-dev alone. Returns 1 with a message on
# stderr, printing nothing, as load_deploy_target does.
handoff_targets() {
    local env="${1:-}" stack="${2:-}" plan_env apply_env
    if [ "$stack" = docs ]; then
        case "$env" in
        dfo-dev) ;;
        dfo-prod)
            echo "ERROR: stack 'docs' hands off only in dfo-dev, the one environment docsync.yml authenticates to." >&2
            return 1
            ;;
        *)
            echo "ERROR: unknown environment '$env' (expected dfo-dev or dfo-prod)." >&2
            return 1
            ;;
        esac
        printf '%s %s %s %s\n' "$(org_repo docs)" docsync "$(environment_branch docs docsync)" docs-sync
        return 0
    fi
    if [ "$stack" = infra ]; then
        if ! plan_env="$(plan_environment "$env")"; then
            echo "ERROR: unknown environment '$env' (expected dfo-dev or dfo-prod)." >&2
            return 1
        fi
        apply_env="$(deploy_environment "$env")"
        printf '%s %s %s %s\n' \
            "$(org_repo infra)" "$plan_env" "$(environment_branch infra "$plan_env")" infra-plan \
            "$(org_repo infra)" "$apply_env" "$(environment_branch infra "$apply_env")" infra-apply
        return 0
    fi
    load_deploy_target "$env" "$stack" || return 1
    printf '%s %s %s %s\n' "$DEPLOY_REPO" "$DEPLOY_GH_ENV" "$DEPLOY_BRANCH" "$stack"
}

# deploy_values <values> prints, one per line, every GitHub variable and
# secret one environment's workflows read, as
#   <var|secret> <NAME> <root> <output>
# where <root> is the stack whose Terraform root holds <output> in the same
# Terraform environment. <values> is a service stack, infra-plan or
# infra-apply for infra's planner and applier environments, or docs-sync for
# docs' docsync environment. Names and
# outputs are the same in dfo-dev and dfo-prod, so the table takes no
# environment. Returns 1, printing nothing, for anything else.
#
# REGION and PROJECT_ID come from foundation, which owns the Artifact
# Registry repos the image path names, so the image path and AR_REPO cannot
# disagree. DFO_SITE_ORIGIN, the website origin whose proxy the dcp
# prototype calls, is baked into the dcp image at build time, so the dcp
# handoff needs the website stack applied first.
deploy_values() {
    local common
    common="var REGION foundation region
var PROJECT_ID foundation project_id
secret WIF_PROVIDER foundation workload_identity_provider
secret WIF_SA foundation ${1:-}_deployer_service_account"
    case "${1:-}" in
    infra-plan)
        printf '%s\n' \
            "var WIF_PROVIDER foundation workload_identity_provider" \
            "var WIF_PLAN_SA foundation planner_service_account"
        ;;
    infra-apply)
        printf '%s\n' \
            "var WIF_PROVIDER foundation workload_identity_provider" \
            "var WIF_APPLY_SA foundation applier_service_account"
        ;;
    docs-sync)
        printf '%s\n' \
            "var GCP_WIF_PROVIDER foundation workload_identity_provider" \
            "var DOCSYNC_SERVICE_ACCOUNT foundation docs_sync_service_account"
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
            "var JOB_DATASETS_MAINTENANCE apis datasets_maintenance_job_name" \
            "var JOB_PRESENTATION_MIGRATE apis presentation_migrate_job_name" \
            "var JOB_COVERAGE apis coverage_job_name" \
            "var JOB_ORIGIN_CATALOGUE apis origin_catalogue_job_name" \
            "var JOB_SEARCH_CATALOGUE apis search_catalogue_job_name"
        ;;
    dcp)
        printf '%s\n' "$common" \
            "var AR_REPO foundation artifact_registry_datacommons_repository_id" \
            "var AR_CACHE_REPO foundation artifact_registry_dcp_build_cache_repository_id" \
            "var DFO_SITE_ORIGIN website website_url"
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
