#!/usr/bin/env bash
# End-to-end tests for handoff.sh and check-deploy-branch-policy.sh against
# stub `gh` and `terraform` commands, so nothing reaches GitHub or GCP. The
# stubs log every call; the cases assert which repo, GitHub Environment,
# variable, secret and Terraform output each environment resolves to. Not
# wired into CI or pre-commit. Run by hand after touching either script or
# deploy-targets.sh:
#   scripts/handoff.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"

# The scripts run from a copy of the repo skeleton, so the Terraform roots
# they cd into exist whatever state this checkout's infra/ is in.
REPO="$WORK/repo"
mkdir -p "$REPO/scripts"
cp "$SCRIPT_DIR"/deploy-targets.sh "$SCRIPT_DIR"/github-environment.sh "$SCRIPT_DIR"/handoff.sh "$SCRIPT_DIR"/check-deploy-branch-policy.sh "$REPO/scripts/"
for env in dfo-dev dfo-prod; do
    for stack in foundation ai apis dcp website; do
        mkdir -p "$REPO/infra/$env/$stack"
    done
done
export STUB_LOG="$WORK/calls.log"

# gh: logs its arguments. `auth status` succeeds. A GET of an environment
# returns one carrying only a branch policy and custom policies on; a listing
# of its branch policies returns the single branch in $STUB_POLICY_BRANCH, so
# the converge step finds nothing to change. Any other call, including every
# write, is only logged.
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$STUB_LOG"
case "$1 $2" in
"auth status") exit 0 ;;
esac
if [ "$1" = api ]; then
    case "$*" in
    *--method*) exit 0 ;;
    *'[.id,'*) printf '1\t%s\tbranch\n' "$STUB_POLICY_BRANCH" ;;
    *deployment-branch-policies*) printf '%s\tbranch\n' "$STUB_POLICY_BRANCH" ;;
    *) echo '{"protection_rules":[{"type":"branch_policy"}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' ;;
    esac
fi
STUB
# terraform: `output -json NAME` prints `"value-of-<env>/<stack>/NAME"`,
# naming the Terraform root it ran in, so an assertion on a written value also
# pins which environment and stack it was read from. NAME equal to
# $STUB_MISSING_OUTPUT exits 1 with nothing on stdout, as Terraform does on an
# unapplied stack. Any other form exits 2, since `output -raw` on an unapplied
# stack exits 0 with a warning on stdout.
cat >"$WORK/bin/terraform" <<'STUB'
#!/usr/bin/env bash
echo "terraform $PWD $*" >>"$STUB_LOG"
[ "$2" = -json ] || { echo "stub: unexpected terraform $*" >&2; exit 2; }
[ "$3" = "${STUB_MISSING_OUTPUT:-}" ] && exit 1
printf '"value-of-%s/%s"\n' "${PWD#*/infra/}" "$3"
STUB
chmod +x "$WORK/bin/gh" "$WORK/bin/terraform"
export PATH="$WORK/bin:$PATH"

# Refuse to continue if the stubs are not what the scripts will resolve.
[ "$(command -v gh)" = "$WORK/bin/gh" ] || { echo "gh stub not first on PATH" >&2; exit 1; }
[ "$(command -v terraform)" = "$WORK/bin/terraform" ] || { echo "terraform stub not first on PATH" >&2; exit 1; }

failures=0

# run <script> <policy-branch> <args...>: runs a script with a fresh log,
# leaving its status in $status, its output in $out and the log in $calls.
run() {
    local script="$1"
    export STUB_POLICY_BRANCH="$2"
    shift 2
    : >"$STUB_LOG"
    set +e
    out="$("$REPO/scripts/$script" "$@" 2>&1)"
    status=$?
    set -e
    calls="$(cat "$STUB_LOG")"
}

# check <label> <true|false>: records a pass or failure, showing the last
# run's output and calls on failure.
check() {
    local label="$1" ok="$2"
    if [ "$ok" = true ]; then
        echo "ok: $label"
    else
        echo "FAIL: $label"
        printf '%s\n' "$out" | sed 's/^/    out: /'
        printf '%s\n' "$calls" | sed 's/^/    log: /'
        failures=$((failures + 1))
    fi
}

says() { [[ "$out" == *"$1"* ]] && echo true || echo false; }
has() { [[ "$calls" == *"$1"* ]] && echo true || echo false; }
lacks() { [[ "$calls" != *"$1"* ]] && echo true || echo false; }

# 1. handoff.sh writes every variable and secret each service repo's
# workflows read, from the right Terraform output, in both environments.
# This list is written out independently of deploy_values, so a change to
# that table must be made here too.
expected_values() {
    if [ "$1" = infra ]; then
        printf '%s\n' \
            "var WIF_PROVIDER foundation workload_identity_provider" \
            "var WIF_PLAN_SA foundation planner_service_account" \
            "var WIF_APPLY_SA foundation applier_service_account"
        return
    fi
    local common="var REGION foundation region
var PROJECT_ID foundation project_id
secret WIF_PROVIDER foundation workload_identity_provider
secret WIF_SA foundation $1_deployer_service_account"
    printf '%s\n' "$common"
    case "$1" in
    ai) printf '%s\n' \
        "var AR_REPO foundation artifact_registry_datacommons_repository_id" \
        "var SERVICE_AI ai service_name" ;;
    apis) printf '%s\n' \
        "var AR_REPO foundation artifact_registry_datacommons_repository_id" \
        "var SERVICE_APIS apis service_name" \
        "var SERVICE_WORKER apis datasets_worker_service_name" \
        "var JOB_DATASETS_MIGRATE apis datasets_migrate_job_name" \
        "var JOB_PRESENTATION_MIGRATE apis presentation_migrate_job_name" \
        "var JOB_COVERAGE apis coverage_job_name" \
        "var JOB_ORIGIN_CATALOGUE apis origin_catalogue_job_name" \
        "var JOB_SEARCH_CATALOGUE apis search_catalogue_job_name" ;;
    dcp) printf '%s\n' \
        "var AR_REPO foundation artifact_registry_datacommons_repository_id" \
        "var AR_CACHE_REPO foundation artifact_registry_dcp_build_cache_repository_id" \
        "var DFO_APIS_BASE_URL apis service_url" ;;
    website) printf '%s\n' \
        "var AR_REPO foundation artifact_registry_website_repository_id" \
        "var SERVICE_WEBSITE website service_name" \
        "var MIGRATE_JOB_WEBSITE website migrate_job_name" ;;
    esac
}

# expect_handoff <env> <stack> <repo> <gh-env> <policy-branch>: runs handoff.sh
# and checks each expected write, that nothing else is written, and that no
# other org's repo is touched.
expect_handoff() {
    local dfo_env="$1" stack="$2" repo="$3" gh_env="$4" kind name root output want writes other
    run handoff.sh "$5" "$dfo_env" "$stack"
    check "$dfo_env $stack exits 0" "$([ "$status" -eq 0 ] && echo true || echo false)"
    want=0
    while read -r kind name root output; do
        [ -z "$kind" ] && continue
        want=$((want + 1))
        [ "$kind" = var ] && kind=variable
        check "$dfo_env $stack sets $kind $name from $root output $output" \
            "$(has "gh $kind set $name --env $gh_env --repo $repo --body value-of-$dfo_env/$root/$output")"
    done <<<"$(expected_values "$stack")"
    writes="$(grep -cE '^gh (variable|secret) set ' "$STUB_LOG" || true)"
    check "$dfo_env $stack writes exactly $want values (wrote $writes)" "$([ "$writes" -eq "$want" ] && echo true || echo false)"
    if [ "$dfo_env" = dfo-prod ]; then other=ONEcampaign; else other=DevelopmentFinanceObservatory; fi
    check "$dfo_env $stack touches no $other repo" "$(lacks "$other")"
    check "$dfo_env $stack reads no other environment's roots" "$(lacks "value-of-$([ "$dfo_env" = dfo-prod ] && echo dfo-dev || echo dfo-prod)")"
}

cases=0
for stack in ai apis dcp; do
    expect_handoff dfo-dev "$stack" "ONEcampaign/dfo-$stack" dev dev
    cases=$((cases + 1))
done
expect_handoff dfo-dev website ONEcampaign/dfo-website staging staging
cases=$((cases + 1))
for stack in ai apis dcp website; do
    expect_handoff dfo-prod "$stack" "DevelopmentFinanceObservatory/$stack" production main
    cases=$((cases + 1))
done
check "handoff covered 8 environment and stack pairs (covered $cases)" "$([ "$cases" -eq 8 ] && echo true || echo false)"

# The infra target writes its three values at repo level on the env's own
# infra repo: no --env, and no environment or branch policy call.
expect_repo_handoff() {
    local dfo_env="$1" repo="$2" kind name root output want=0 writes
    run handoff.sh main "$dfo_env" infra
    check "$dfo_env infra exits 0" "$([ "$status" -eq 0 ] && echo true || echo false)"
    while read -r kind name root output; do
        [ -z "$kind" ] && continue
        want=$((want + 1))
        check "$dfo_env infra sets repo-level variable $name from $root output $output" \
            "$(has "gh variable set $name --repo $repo --body value-of-$dfo_env/$root/$output")"
    done <<<"$(expected_values infra)"
    writes="$(grep -cE '^gh variable set ' "$STUB_LOG" || true)"
    check "$dfo_env infra writes exactly $want variables (wrote $writes)" "$([ "$want" -eq 3 ] && [ "$writes" -eq "$want" ] && echo true || echo false)"
    check "$dfo_env infra writes no secret" "$(lacks 'gh secret set')"
    check "$dfo_env infra writes nothing environment-scoped" "$(lacks ' --env ')"
    check "$dfo_env infra makes no environment or policy call" "$(lacks 'gh api')"
}
expect_repo_handoff dfo-dev ONEcampaign/dfo-infra
check "dev infra touches no prod repo" "$(lacks DevelopmentFinanceObservatory)"
expect_repo_handoff dfo-prod DevelopmentFinanceObservatory/infra
check "prod infra touches no ONEcampaign repo" "$(lacks ONEcampaign)"

run handoff.sh main dfo-prod apis
check "prod apis makes no policy write (already converged on main)" "$(lacks '--method')"

# A missing output stops the run before any policy change or write.
export STUB_MISSING_OUTPUT=migrate_job_name
run handoff.sh staging dfo-dev website
unset STUB_MISSING_OUTPUT
check "missing output exits 1" "$([ "$status" -eq 1 ] && echo true || echo false)"
check "missing output names the output" "$(says "Could not read output 'migrate_job_name'")"
check "missing output writes nothing" "$(lacks ' set ')"
check "missing output changes no policy" "$(lacks '--method')"

# 2. A stale policy is converged to the table's branch, never left in place.
run handoff.sh dev dfo-prod ai
check "prod ai with a stale 'dev' policy adds main" "$(has 'gh api --method POST repos/DevelopmentFinanceObservatory/ai/environments/production/deployment-branch-policies -f name=main -f type=branch')"

# 3. Bad input fails before any gh or terraform call.
run handoff.sh dev dfo-staging ai
check "handoff unknown env exits 1" "$([ "$status" -eq 1 ] && echo true || echo false)"
check "handoff unknown env names it" "$(says "unknown environment 'dfo-staging'")"
check "handoff unknown env makes no call" "$([ -z "$calls" ] && echo true || echo false)"

run handoff.sh dev dfo-prod foundation
check "handoff unknown stack exits 1" "$([ "$status" -eq 1 ] && echo true || echo false)"
check "handoff unknown stack makes no call" "$([ -z "$calls" ] && echo true || echo false)"

run handoff.sh dev ai
check "handoff without an env exits 1 (the old stack-only form)" "$([ "$status" -eq 1 ] && echo true || echo false)"
check "handoff old stack-only form makes no call" "$([ -z "$calls" ] && echo true || echo false)"

run handoff.sh dev
check "handoff with one argument exits 1" "$([ "$status" -eq 1 ] && echo true || echo false)"

# 4. check-deploy-branch-policy.sh audits the same table.
run check-deploy-branch-policy.sh main dfo-prod
check "prod audit passes when every repo has only main" "$([ "$status" -eq 0 ] && echo true || echo false)"
for stack in ai apis dcp website; do
    check "prod audit reads DevelopmentFinanceObservatory/$stack production" "$(has "gh api --paginate repos/DevelopmentFinanceObservatory/$stack/environments/production/deployment-branch-policies")"
done
check "prod audit touches no ONEcampaign repo" "$(lacks ONEcampaign)"

run check-deploy-branch-policy.sh dev dfo-prod apis
check "prod audit fails on a wrong branch" "$([ "$status" -eq 1 ] && echo true || echo false)"
check "prod audit failure names the expected branch" "$(says 'expected exactly {name=main, type=branch}')"

run check-deploy-branch-policy.sh staging dfo-dev website
check "dev website audit passes on staging" "$([ "$status" -eq 0 ] && echo true || echo false)"
check "dev website audit reads ONEcampaign/dfo-website staging" "$(has 'repos/ONEcampaign/dfo-website/environments/staging/deployment-branch-policies')"

run check-deploy-branch-policy.sh dev dfo-dev
check "dev audit fails when website's staging is not the branch" "$([ "$status" -eq 1 ] && echo true || echo false)"
check "dev audit covers ai, apis, dcp and website" "$(has 'repos/ONEcampaign/dfo-ai/' )"

run check-deploy-branch-policy.sh dev dfo-nope
check "audit unknown env exits 1" "$([ "$status" -eq 1 ] && echo true || echo false)"
run check-deploy-branch-policy.sh dev dfo-nope apis
check "audit unknown env with a stack exits 1" "$([ "$status" -eq 1 ] && echo true || echo false)"
check "audit unknown env with a stack makes no api call" "$(lacks 'gh api')"
run check-deploy-branch-policy.sh dev dfo-prod foundation
check "audit unknown stack exits 1" "$([ "$status" -eq 1 ] && echo true || echo false)"
run check-deploy-branch-policy.sh dev
check "audit with no env exits 1" "$([ "$status" -eq 1 ] && echo true || echo false)"

if [ "$failures" -eq 0 ]; then
    echo "All scenarios passed."
    exit 0
else
    echo "$failures scenario(s) failed."
    exit 1
fi
