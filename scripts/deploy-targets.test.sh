#!/usr/bin/env bash
# Scenario tests for deploy-targets.sh. Not wired into CI or pre-commit,
# matching check-image-pin-diff.test.sh. Run by hand after touching the
# table:
#   scripts/deploy-targets.test.sh
#
# load_deploy_target maps an environment (dfo-dev or dfo-prod) and a stack to
# the service repo, GitHub Environment, and deploy branch. The cases below
# pin every row, and that an unknown environment or stack fails closed
# rather than falling back to a default. handoff_targets adds infra's two
# environments on top. deploy_values is pinned in full by handoff.test.sh,
# which checks what handoff.sh writes from it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # dynamic path; deploy-targets.sh lives beside this
source "$SCRIPT_DIR/deploy-targets.sh"

failures=0

# expect_target <label> <env> <stack> <repo> <gh_env> <branch> asserts
# load_deploy_target returns 0 and sets exactly these values.
expect_target() {
    local label="$1" env="$2" stack="$3" repo="$4" gh_env="$5" branch="$6"
    local status
    set +e
    load_deploy_target "$env" "$stack" 2>/dev/null
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
        echo "FAIL: $label -- returned $status, expected 0"
        failures=$((failures + 1))
    elif [ "$DEPLOY_REPO|$DEPLOY_GH_ENV|$DEPLOY_BRANCH" != "$repo|$gh_env|$branch" ]; then
        echo "FAIL: $label -- got '$DEPLOY_REPO|$DEPLOY_GH_ENV|$DEPLOY_BRANCH', expected '$repo|$gh_env|$branch'"
        failures=$((failures + 1))
    else
        echo "ok: $label -> $DEPLOY_REPO ($DEPLOY_GH_ENV, $DEPLOY_BRANCH)"
    fi
}

# expect_unknown <label> <env> <stack> <message-fragment> asserts
# load_deploy_target returns 1, leaves every variable empty (handoff.sh
# would otherwise use a stray value as a branch name), and says why on
# stderr.
expect_unknown() {
    local label="$1" env="$2" stack="$3" fragment="$4"
    local status err
    set +e
    err="$(load_deploy_target "$env" "$stack" 2>&1 >/dev/null)"
    load_deploy_target "$env" "$stack" 2>/dev/null
    status=$?
    set -e
    if [ "$status" -ne 1 ]; then
        echo "FAIL: $label -- returned $status, expected 1"
        failures=$((failures + 1))
    elif [ -n "$DEPLOY_REPO$DEPLOY_GH_ENV$DEPLOY_BRANCH" ]; then
        echo "FAIL: $label -- returned 1 but left a value set"
        failures=$((failures + 1))
    elif [[ "$err" != *"$fragment"* ]]; then
        echo "FAIL: $label -- stderr '$err' lacks '$fragment'"
        failures=$((failures + 1))
    else
        echo "ok: $label -> unknown, as expected"
    fi
}

# check <label> <true|false>
check() {
    if [ "$2" = true ]; then
        echo "ok: $1"
    else
        echo "FAIL: $1"
        failures=$((failures + 1))
    fi
}
is() { [ "$1" = "$2" ] && echo true || echo false; }

# 1. dfo-dev: every service repo, website included, deploys from dev
# through environment dev.
covered=0
for stack in ai apis dcp website; do
    expect_target "dev $stack" dfo-dev "$stack" "DevelopmentFinanceObservatory/$stack" dev dev
    expect_target "prod $stack" dfo-prod "$stack" "DevelopmentFinanceObservatory/$stack" production main
    covered=$((covered + 1))
done
check "covered 4 stacks in both environments (covered $covered)" "$(is "$covered" 4)"

# 2. Fail closed.
expect_unknown "unknown environment" dfo-staging ai "unknown environment 'dfo-staging'"
expect_unknown "short environment name" dev ai "unknown environment 'dev'"
expect_unknown "empty environment" "" ai "unknown environment"
expect_unknown "stack without a service repo (dev)" dfo-dev foundation "stack 'foundation' is not a deploy target in dfo-dev"
expect_unknown "stack without a service repo (prod)" dfo-prod platform "stack 'platform' is not a deploy target in dfo-prod"
expect_unknown "infra is no deploy target" dfo-prod infra "stack 'infra' is not a deploy target in dfo-prod"
expect_unknown "empty stack" dfo-prod "" "is not a deploy target"

# 3. handoff_targets: a service stack writes to its deploy environment;
# infra writes to its planner and applier environments per the contract.
check "handoff_targets dfo-dev website" "$(is "$(handoff_targets dfo-dev website)" "DevelopmentFinanceObservatory/website dev dev website")"
check "handoff_targets dfo-prod dcp" "$(is "$(handoff_targets dfo-prod dcp)" "DevelopmentFinanceObservatory/dcp production main dcp")"
check "handoff_targets dfo-dev infra: dev-plan with no branch, dev on dev" "$(is "$(handoff_targets dfo-dev infra)" "DevelopmentFinanceObservatory/infra dev-plan - infra-plan
DevelopmentFinanceObservatory/infra dev dev infra-apply")"
check "handoff_targets dfo-prod infra: plan and production on main" "$(is "$(handoff_targets dfo-prod infra)" "DevelopmentFinanceObservatory/infra plan main infra-plan
DevelopmentFinanceObservatory/infra production main infra-apply")"
check "handoff_targets dfo-dev docs: docsync on dev" "$(is "$(handoff_targets dfo-dev docs)" "DevelopmentFinanceObservatory/docs docsync dev docs-sync")"
check "handoff_targets refuses docs in dfo-prod" "$(handoff_targets dfo-prod docs >/dev/null 2>&1 && echo false || echo true)"
check "handoff_targets refuses an unknown environment for docs" "$(handoff_targets dfo-nope docs >/dev/null 2>&1 && echo false || echo true)"
check "handoff_targets refuses an unknown environment for infra" "$(handoff_targets dfo-nope infra >/dev/null 2>&1 && echo false || echo true)"
check "handoff_targets refuses an unknown stack" "$(handoff_targets dfo-dev foundation >/dev/null 2>&1 && echo false || echo true)"

# 4. deploy_values for infra: the planner gets the provider and planner, the
# applier the provider and applier, all from foundation.
check "deploy_values infra-plan" "$(is "$(deploy_values infra-plan)" "var WIF_PROVIDER foundation workload_identity_provider
var WIF_PLAN_SA foundation planner_service_account")"
check "deploy_values infra-apply" "$(is "$(deploy_values infra-apply)" "var WIF_PROVIDER foundation workload_identity_provider
var WIF_APPLY_SA foundation applier_service_account")"
check "deploy_values docs-sync" "$(is "$(deploy_values docs-sync)" "var GCP_WIF_PROVIDER foundation workload_identity_provider
var DOCSYNC_SERVICE_ACCOUNT foundation docs_sync_service_account")"
check "deploy_values refuses infra and foundation" "$(deploy_values infra >/dev/null || deploy_values foundation >/dev/null || echo true)"

# 5. The environment table: infra's contract, the service repos' deploy
# environments with release reviewers on production, and docs' docsync.
check "infra environments" "$(is "$(repo_environments infra)" "dev-plan - -
dev dev -
plan main release
production main release")"
for stack in ai apis dcp website; do
    check "$stack environments" "$(is "$(repo_environments "$stack")" "dev dev -
production main release")"
done
check "docs environments" "$(is "$(repo_environments docs)" "docsync dev -")"
check "pipelines has no environment" "$(is "$(repo_environments pipelines)" "")"
check "repo_environments refuses an unknown repo" "$(repo_environments nope >/dev/null && echo false || echo true)"
check "environment_branch infra dev-plan is -" "$(is "$(environment_branch infra dev-plan)" -)"
check "environment_branch refuses an unlisted environment" "$(environment_branch infra staging >/dev/null && echo false || echo true)"

# 6. Repos, names and default branches.
check "org_repos lists the ten repos" "$(is "$(org_repos)" "infra dcp apis ai website pipelines docs ontology spec-kit skills")"
check "org_repo maps spec-kit" "$(is "$(org_repo spec-kit)" DevelopmentFinanceObservatory/spec-kit)"
check "org_repo refuses an unknown or empty name" "$(org_repo foundation >/dev/null || org_repo "" >/dev/null || echo true)"
defaults=""
for name in $(org_repos); do defaults="$defaults $name=$(default_branch "$name")"; done
check "default branches: main for infra, dev elsewhere" "$(is "$defaults" " infra=main dcp=dev apis=dev ai=dev website=dev pipelines=dev docs=dev ontology=dev spec-kit=dev skills=dev")"
check "deploy_stacks lists four stacks and refuses an unknown environment" "$([ "$(deploy_stacks dfo-prod)" = "ai apis dcp website" ] && ! deploy_stacks dfo-nope >/dev/null && echo true || echo false)"
check "deploy_tf_dir" "$(is "$(deploy_tf_dir dfo-prod dcp)" infra/dfo-prod/dcp)"

if [ "$failures" -eq 0 ]; then
    echo "All scenarios passed."
    exit 0
else
    echo "$failures scenario(s) failed."
    exit 1
fi
