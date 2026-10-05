#!/usr/bin/env bash
# Scenario tests for deploy-targets.sh. Not wired into CI or pre-commit,
# matching check-image-pin-diff.test.sh. Run by hand after touching the
# table:
#   scripts/deploy-targets.test.sh
#
# load_deploy_target maps an environment (dfo-dev or dfo-prod) and a stack to
# the service repo, GitHub Environment, and deploy branch. The cases below
# pin every row of the table, and that an unknown environment or stack fails
# closed rather than falling back to a default. load_handoff_target adds the
# repo-level infra target on top of that table. deploy_values is pinned in
# full by handoff.test.sh, which checks what handoff.sh writes from it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # dynamic path; deploy-targets.sh lives beside this
source "$SCRIPT_DIR/deploy-targets.sh"

failures=0

# expect_target <label> <env> <stack> <repo> <gh_env> <branch> [lookup] --
# asserts the lookup (default load_deploy_target) returns 0 and sets exactly
# these values.
expect_target() {
    local label="$1" env="$2" stack="$3" repo="$4" gh_env="$5" branch="$6" lookup="${7:-load_deploy_target}"
    local status
    set +e
    "$lookup" "$env" "$stack" 2>/dev/null
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

# expect_unknown <label> <env> <stack> <message-fragment> [lookup] -- asserts
# the lookup (default load_deploy_target) returns 1, leaves every variable
# empty (handoff.sh would otherwise use a stray value as a branch name), and
# says why on stderr.
expect_unknown() {
    local label="$1" env="$2" stack="$3" fragment="$4" lookup="${5:-load_deploy_target}"
    local status err
    set +e
    err="$("$lookup" "$env" "$stack" 2>&1 >/dev/null)"
    "$lookup" "$env" "$stack" 2>/dev/null
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

# 1. dfo-dev: ONEcampaign/dfo-<stack>, environment dev, branch dev.
expect_target "dev ai" dfo-dev ai ONEcampaign/dfo-ai dev dev
expect_target "dev apis" dfo-dev apis ONEcampaign/dfo-apis dev dev
expect_target "dev dcp" dfo-dev dcp ONEcampaign/dfo-dcp dev dev

# 2. dfo-website deploys only its staging environment, from the staging
# branch.
expect_target "dev website" dfo-dev website ONEcampaign/dfo-website staging staging

# 3. dfo-prod: the new org, no dfo- prefix, environment production, main.
expect_target "prod ai" dfo-prod ai DevelopmentFinanceObservatory/ai production main
expect_target "prod apis" dfo-prod apis DevelopmentFinanceObservatory/apis production main
expect_target "prod dcp" dfo-prod dcp DevelopmentFinanceObservatory/dcp production main
expect_target "prod website" dfo-prod website DevelopmentFinanceObservatory/website production main

# 4. Fail closed.
expect_unknown "unknown environment" dfo-staging ai "unknown environment 'dfo-staging'"
expect_unknown "short environment name" dev ai "unknown environment 'dev'"
expect_unknown "empty environment" "" ai "unknown environment"
expect_unknown "stack without a service repo (dev)" dfo-dev foundation "stack 'foundation' is not a deploy target in dfo-dev"
expect_unknown "stack without a service repo (prod)" dfo-prod platform "stack 'platform' is not a deploy target in dfo-prod"
expect_unknown "dev-only stack in prod" dfo-prod pipelines "stack 'pipelines' is not a deploy target in dfo-prod"
expect_unknown "empty stack" dfo-prod "" "is not a deploy target"

# 5. load_handoff_target: infra is the env's own infra repo, repo-level (no
# GitHub Environment, no branch); every other stack resolves exactly as
# load_deploy_target does; infra is no deploy target for the branch audit.
expect_target "handoff dev infra" dfo-dev infra ONEcampaign/dfo-infra "" "" load_handoff_target
expect_target "handoff prod infra" dfo-prod infra DevelopmentFinanceObservatory/infra "" "" load_handoff_target
expect_target "handoff dev website" dfo-dev website ONEcampaign/dfo-website staging staging load_handoff_target
expect_target "handoff prod apis" dfo-prod apis DevelopmentFinanceObservatory/apis production main load_handoff_target
expect_unknown "handoff infra in an unknown environment" dfo-staging infra "unknown environment 'dfo-staging'" load_handoff_target
expect_unknown "handoff stack without a service repo" dfo-prod foundation "stack 'foundation' is not a deploy target in dfo-prod" load_handoff_target
expect_unknown "infra is not a branch-policy deploy target" dfo-prod infra "stack 'infra' is not a deploy target in dfo-prod"

# 6. deploy_values for infra: the three repo-level values the plan and apply
# workflows read, all from foundation.
if [ "$(deploy_values infra)" = "var WIF_PROVIDER foundation workload_identity_provider
var WIF_PLAN_SA foundation planner_service_account
var WIF_APPLY_SA foundation applier_service_account" ] && ! deploy_values foundation >/dev/null; then
    echo "ok: deploy_values infra lists WIF_PROVIDER, WIF_PLAN_SA and WIF_APPLY_SA from foundation"
else
    echo "FAIL: deploy_values infra"
    failures=$((failures + 1))
fi

# 7. deploy_stacks and deploy_tf_dir.
if [ "$(deploy_stacks dfo-prod)" = "ai apis dcp website" ] && ! deploy_stacks dfo-nope >/dev/null; then
    echo "ok: deploy_stacks lists prod's four stacks and rejects an unknown environment"
else
    echo "FAIL: deploy_stacks"
    failures=$((failures + 1))
fi
if [ "$(deploy_tf_dir dfo-prod dcp)" = "infra/dfo-prod/dcp" ]; then
    echo "ok: deploy_tf_dir -> infra/dfo-prod/dcp"
else
    echo "FAIL: deploy_tf_dir"
    failures=$((failures + 1))
fi

# 8. org_repos and org_repo.
if [ "$(org_repos dfo-dev)" = "infra dcp apis ai website pipelines docs ontology spec-kit skills" ] &&
    [ "$(org_repos dfo-prod)" = "$(org_repos dfo-dev)" ] && ! org_repos dfo-nope >/dev/null; then
    echo "ok: org_repos lists the same ten repos in both environments and rejects an unknown one"
else
    echo "FAIL: org_repos"
    failures=$((failures + 1))
fi
if [ "$(org_repo dfo-dev spec-kit)" = "ONEcampaign/dfo-spec-kit" ] &&
    [ "$(org_repo dfo-prod spec-kit)" = "DevelopmentFinanceObservatory/spec-kit" ]; then
    echo "ok: org_repo maps spec-kit to each org's name"
else
    echo "FAIL: org_repo naming"
    failures=$((failures + 1))
fi
if ! org_repo dfo-prod foundation >/dev/null && ! org_repo dfo-prod "" >/dev/null &&
    ! org_repo dfo-nope ai >/dev/null && [ -z "$(org_repo dfo-dev nope || true)" ]; then
    echo "ok: org_repo rejects an unknown repo or environment, printing nothing"
else
    echo "FAIL: org_repo fail-closed"
    failures=$((failures + 1))
fi

if [ "$failures" -eq 0 ]; then
    echo "All scenarios passed."
    exit 0
else
    echo "$failures scenario(s) failed."
    exit 1
fi
