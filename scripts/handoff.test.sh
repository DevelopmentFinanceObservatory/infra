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

# gh: logs its arguments. `auth status` succeeds. An environment GET
# answers as setup-github-repos.sh leaves it: `dev-plan` with no branch
# policy, every other environment with custom policies, listing one branch:
# $STUB_POLICY_BRANCH if set, else `main` for plan and production and `dev`
# otherwise. The environment path in $STUB_MISSING_ENV answers 404. Any
# other call, including every write, is only logged.
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$STUB_LOG"
case "$1 $2" in
"auth status") exit 0 ;;
esac
[ "$1" = api ] || exit 0
case "$*" in *--method*) exit 0 ;; esac
path=""
for a in "$@"; do case "$a" in repos/*) path="$a" ;; esac; done
env_path="${path%/deployment-branch-policies}"
if [ -n "${STUB_MISSING_ENV:-}" ] && [ "$env_path" = "$STUB_MISSING_ENV" ]; then
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
fi
env="${env_path##*/}"
case "$env" in
plan | production) branch=main ;;
*) branch=dev ;;
esac
branch="${STUB_POLICY_BRANCH:-$branch}"
case "$path" in
*/deployment-branch-policies) printf '%s\tbranch\n' "$branch" ;;
*/environments/dev-plan) echo '{"protection_rules":[],"deployment_branch_policy":null}' ;;
*/environments/*) echo '{"protection_rules":[{"type":"branch_policy"}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' ;;
esac
STUB
# terraform: `output -json NAME` prints `"value-of-<env>/<stack>/NAME"`,
# naming the Terraform root it ran in, so an assertion on a written value also
# pins which environment and stack it was read from. An output missing from
# state exits 1 with Terraform's `Output "NAME" not found` on stderr and
# nothing on stdout. Terraform stores no null output, so an output whose
# resource is off is missing exactly as an unapplied one is, and the stub
# never prints `null`. Missing are NAME equal to $STUB_MISSING_OUTPUT, in any
# root, and each `<env>/<stack>/NAME` in $STUB_ABSENT_OUTPUTS. Any other form
# exits 2, since `output -raw` on an unapplied stack exits 0 with a warning on
# stdout.
cat >"$WORK/bin/terraform" <<'STUB'
#!/usr/bin/env bash
echo "terraform $PWD $*" >>"$STUB_LOG"
[ "$2" = -json ] || { echo "stub: unexpected terraform $*" >&2; exit 2; }
root="${PWD#*/infra/}"
case " ${STUB_ABSENT_OUTPUTS:-} " in
*" $root/$3 "*) missing=true ;;
*) [ "$3" = "${STUB_MISSING_OUTPUT:-}" ] && missing=true || missing=false ;;
esac
if [ "$missing" = true ]; then
    printf 'Error: Output "%s" not found\n' "$3" >&2
    exit 1
fi
printf '"value-of-%s/%s"\n' "$root" "$3"
STUB
chmod +x "$WORK/bin/gh" "$WORK/bin/terraform"
export PATH="$WORK/bin:$PATH"

# The outputs dfo-dev's state lacks because their resources are off there:
# langfuse_export_job_name and export_job_name (both exports default off). Every case runs against
# that state shape unless it says otherwise.
DEV_ABSENT_OUTPUTS="dfo-dev/ai/langfuse_export_job_name dfo-dev/website/export_job_name"
export STUB_ABSENT_OUTPUTS="$DEV_ABSENT_OUTPUTS"

# Refuse to continue if the stubs are not what the scripts will resolve.
[ "$(command -v gh)" = "$WORK/bin/gh" ] || { echo "gh stub not first on PATH" >&2; exit 1; }
[ "$(command -v terraform)" = "$WORK/bin/terraform" ] || { echo "terraform stub not first on PATH" >&2; exit 1; }

failures=0

# run <script> <args...>: runs a script with a fresh log, leaving its
# status in $status, its output in $out and the log in $calls.
run() {
    local script="$1"
    shift
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

# 1. handoff.sh writes every variable and secret each environment's
# workflows read, from the right Terraform output, in both environments.
# This list is written out independently of deploy_values, so a change to
# that table must be made here too. The second argument is the Terraform
# environment, for rows that exist in dfo-prod alone.
expected_values() {
    case "$1" in
    infra-plan)
        printf '%s\n' \
            "var WIF_PROVIDER foundation workload_identity_provider" \
            "var WIF_PLAN_SA foundation planner_service_account"
        return
        ;;
    infra-apply)
        printf '%s\n' \
            "var WIF_PROVIDER foundation workload_identity_provider" \
            "var WIF_APPLY_SA foundation applier_service_account"
        return
        ;;
    docs-sync)
        printf '%s\n' \
            "var GCP_WIF_PROVIDER foundation workload_identity_provider" \
            "var DOCSYNC_SERVICE_ACCOUNT foundation docs_sync_service_account"
        return
        ;;
    esac
    local common="var REGION foundation region
var PROJECT_ID foundation project_id
secret WIF_PROVIDER foundation workload_identity_provider
secret WIF_SA foundation $1_deployer_service_account"
    printf '%s\n' "$common"
    case "$1" in
    ai)
        printf '%s\n' \
            "var AR_REPO foundation artifact_registry_datacommons_repository_id" \
            "var SERVICE_AI ai service_name"
        [ "$2" = dfo-prod ] && printf '%s\n' "var JOB_LANGFUSE_EXPORT ai langfuse_export_job_name"
        ;;
    apis)
        printf '%s\n' \
        "var AR_REPO foundation artifact_registry_datacommons_repository_id" \
        "var SERVICE_APIS apis service_name" \
        "var SERVICE_WORKER apis datasets_worker_service_name" \
        "var JOB_DATASETS_MIGRATE apis datasets_migrate_job_name" \
        "var JOB_DATASETS_MAINTENANCE apis datasets_maintenance_job_name" \
        "var JOB_PRESENTATION_MIGRATE apis presentation_migrate_job_name" \
        "var JOB_ORIGIN_CATALOGUE apis origin_catalogue_job_name" \
        "var JOB_GRAPH_RELEASE apis graph_release_job_name" \
        "var JOB_SEARCH_CATALOGUE apis search_catalogue_job_name"
        ;;
    dcp) printf '%s\n' \
        "var AR_REPO foundation artifact_registry_datacommons_repository_id" \
        "var AR_CACHE_REPO foundation artifact_registry_dcp_build_cache_repository_id" \
        "var DFO_SITE_ORIGIN website website_url" ;;
    website)
        printf '%s\n' \
            "var AR_REPO foundation artifact_registry_website_repository_id" \
            "var SERVICE_WEBSITE website service_name" \
            "var MIGRATE_JOB_WEBSITE website migrate_job_name" \
            "var SHARE_MIGRATE_JOB_WEBSITE website share_migrate_job_name"
        [ "$2" = dfo-prod ] && printf '%s\n' "var EXPORT_JOB_WEBSITE website export_job_name"
        ;;
    esac
}

# expect_writes <env> <stack> <repo> <gh-env> <values>: checks the last run
# set each of <values>' entries in <gh-env>, read from <env>'s roots, and
# adds their count to $want.
expect_writes() {
    local dfo_env="$1" stack="$2" repo="$3" gh_env="$4" kind name root output
    while read -r kind name root output; do
        [ -z "$kind" ] && continue
        want=$((want + 1))
        [ "$kind" = var ] && kind=variable
        check "$dfo_env $stack sets $kind $name in $gh_env from $root output $output" \
            "$(has "gh $kind set $name --env $gh_env --repo $repo --body value-of-$dfo_env/$root/$output")"
    done <<<"$(expected_values "$5" "$dfo_env")"
}

# finish_case <env> <stack>: the write count, and no other environment's roots.
finish_case() {
    local writes other
    writes="$(grep -cE '^gh (variable|secret) set ' "$STUB_LOG" || true)"
    check "$1 $2 writes exactly $want values (wrote $writes)" "$([ "$writes" -eq "$want" ] && echo true || echo false)"
    other="$([ "$1" = dfo-prod ] && echo dfo-dev || echo dfo-prod)"
    check "$1 $2 reads no $other root" "$(lacks "value-of-$other")"
    check "$1 $2 writes nothing at repo level" "$(is "$(grep -E '^gh (variable|secret) set ' "$STUB_LOG" | grep -vc ' --env ' || true)" 0)"
    check "$1 $2 changes no environment" "$(lacks '--method')"
    check "$1 $2 touches no ONEcampaign repo" "$(lacks ONEcampaign)"
}

is() { [ "$1" = "$2" ] && echo true || echo false; }

cases=0
for dfo_env in dfo-dev dfo-prod; do
    gh_env="$([ "$dfo_env" = dfo-dev ] && echo dev || echo production)"
    for stack in ai apis dcp website; do
        run handoff.sh "$dfo_env" "$stack"
        check "$dfo_env $stack exits 0" "$(is "$status" 0)"
        want=0
        expect_writes "$dfo_env" "$stack" "DevelopmentFinanceObservatory/$stack" "$gh_env" "$stack"
        finish_case "$dfo_env" "$stack"
        cases=$((cases + 1))
    done
done
check "handoff covered 8 environment and stack pairs (covered $cases)" "$(is "$cases" 8)"

# 2. infra writes the environment contract: the planner's values in
# dev-plan or plan, the applier's in dev or production, nothing at repo
# level.
run handoff.sh dfo-dev infra
check "dfo-dev infra exits 0" "$(is "$status" 0)"
want=0
expect_writes dfo-dev infra DevelopmentFinanceObservatory/infra dev-plan infra-plan
expect_writes dfo-dev infra DevelopmentFinanceObservatory/infra dev infra-apply
finish_case dfo-dev infra
check "dfo-dev infra checks dev-plan has no branch policy" "$(says 'PASS  DevelopmentFinanceObservatory/infra (dev-plan): no branch policy')"
check "dfo-dev infra writes no applier into dev-plan" "$(lacks 'WIF_APPLY_SA --env dev-plan')"

run handoff.sh dfo-prod infra
check "dfo-prod infra exits 0" "$(is "$status" 0)"
want=0
expect_writes dfo-prod infra DevelopmentFinanceObservatory/infra plan infra-plan
expect_writes dfo-prod infra DevelopmentFinanceObservatory/infra production infra-apply
finish_case dfo-prod infra
check "dfo-prod infra writes no applier into plan" "$(lacks 'WIF_APPLY_SA --env plan')"

# docs writes docsync.yml's two values into docsync, in dfo-dev only.
run handoff.sh dfo-dev docs
check "dfo-dev docs exits 0" "$(is "$status" 0)"
want=0
expect_writes dfo-dev docs DevelopmentFinanceObservatory/docs docsync docs-sync
finish_case dfo-dev docs
check "dfo-dev docs checks docsync admits only dev" "$(has 'repos/DevelopmentFinanceObservatory/docs/environments/docsync/deployment-branch-policies')"

run handoff.sh dfo-prod docs
check "dfo-prod docs exits 1" "$(is "$status" 1)"
check "dfo-prod docs makes no call" "$(is "$calls" "")"

# 3. A missing output stops the run before any write.
export STUB_MISSING_OUTPUT=migrate_job_name
run handoff.sh dfo-dev website
unset STUB_MISSING_OUTPUT
check "missing output exits 1" "$(is "$status" 1)"
check "missing output names the output" "$(says "Could not read output 'migrate_job_name'")"
check "missing output writes nothing" "$(lacks ' set ')"

# 3a. The stub reports a missing output as Terraform does: exit 1, the error
# on stderr, nothing on stdout, and never `null`.
set +e
stub_out="$(cd "$REPO/infra/dfo-dev/ai" && terraform output -json langfuse_export_job_name 2>/dev/null)"
stub_status=$?
stub_err="$(cd "$REPO/infra/dfo-dev/ai" && terraform output -json langfuse_export_job_name 2>&1 >/dev/null)"
set -e
check "stub: a missing output exits 1" "$(is "$stub_status" 1)"
check "stub: a missing output prints nothing on stdout" "$(is "$stub_out" "")"
check "stub: a missing output says Output not found" "$(is "$stub_err" 'Error: Output "langfuse_export_job_name" not found')"

# 3b. Each prod-only output is missing from dfo-dev's state, so dfo-dev
# succeeds without reading it. dfo-prod fails when the output is missing, as
# it does before the apply that creates it.
prod_only=0
while read -r stack output name; do
    [ -z "$stack" ] && continue
    run handoff.sh dfo-dev "$stack"
    check "dfo-dev $stack exits 0 without $output in its state" "$(is "$status" 0)"
    check "dfo-dev $stack never reads $output" "$(lacks "$output")"
    check "dfo-dev $stack sets no $name" "$(lacks "$name")"
    export STUB_MISSING_OUTPUT="$output"
    run handoff.sh dfo-prod "$stack"
    unset STUB_MISSING_OUTPUT
    check "dfo-prod $stack exits 1 without $output" "$(is "$status" 1)"
    check "dfo-prod $stack names the missing output" "$(says "Could not read output '$output'")"
    check "dfo-prod $stack writes nothing without $output" "$(lacks ' set ')"
    prod_only=$((prod_only + 1))
done <<'ROWS'
ai langfuse_export_job_name JOB_LANGFUSE_EXPORT
website export_job_name EXPORT_JOB_WEBSITE
ROWS
check "covered 2 prod-only outputs (covered $prod_only)" "$(is "$prod_only" 2)"

# 4. A missing or mis-restricted environment stops the run before any write,
# and handoff never creates or fixes one.
export STUB_MISSING_ENV=repos/DevelopmentFinanceObservatory/infra/environments/production
run handoff.sh dfo-prod infra
unset STUB_MISSING_ENV
check "missing environment exits 1" "$(is "$status" 1)"
check "missing environment is named" "$(says 'DevelopmentFinanceObservatory/infra (production): environment does not exist')"
check "missing environment writes nothing, plan included" "$(lacks ' set ')"
check "missing environment creates nothing" "$(lacks '--method')"

export STUB_POLICY_BRANCH=staging
run handoff.sh dfo-dev ai
check "stale branch policy exits 1" "$(is "$status" 1)"
check "stale branch policy names the expected branch" "$(says 'expected exactly {name=dev, type=branch}')"
check "stale branch policy writes nothing" "$(lacks ' set ')"
check "stale branch policy is left alone" "$(lacks '--method')"
unset STUB_POLICY_BRANCH

# 5. Bad input fails before any gh or terraform call.
run handoff.sh dfo-staging ai
check "handoff unknown env exits 1" "$(is "$status" 1)"
check "handoff unknown env names it" "$(says "unknown environment 'dfo-staging'")"
check "handoff unknown env makes no call" "$(is "$calls" "")"
run handoff.sh dfo-staging infra
check "handoff infra in an unknown env exits 1" "$(is "$status" 1)"
check "handoff infra in an unknown env makes no call" "$(is "$calls" "")"
run handoff.sh dfo-prod foundation
check "handoff unknown stack exits 1" "$(is "$status" 1)"
check "handoff unknown stack makes no call" "$(is "$calls" "")"
run handoff.sh ai
check "handoff with one argument exits 1" "$(is "$status" 1)"
check "handoff with one argument makes no call" "$(is "$calls" "")"

# 6. check-deploy-branch-policy.sh audits the same table.
run check-deploy-branch-policy.sh dfo-prod
check "prod audit passes when every repo has only main" "$(is "$status" 0)"
for stack in ai apis dcp website; do
    check "prod audit reads $stack production" "$(has "gh api --paginate repos/DevelopmentFinanceObservatory/$stack/environments/production/deployment-branch-policies")"
done
run check-deploy-branch-policy.sh dfo-dev website
check "dev website audit passes on dev" "$(is "$status" 0)"
check "dev website audit reads the dev environment" "$(has 'repos/DevelopmentFinanceObservatory/website/environments/dev/deployment-branch-policies')"
export STUB_POLICY_BRANCH=main
run check-deploy-branch-policy.sh dfo-dev
unset STUB_POLICY_BRANCH
check "dev audit fails when dev admits main" "$(is "$status" 1)"
check "dev audit reports all four" "$(is "$(printf '%s\n' "$out" | grep -c '^FAIL ')" 4)"
export STUB_MISSING_ENV=repos/DevelopmentFinanceObservatory/dcp/environments/dev
run check-deploy-branch-policy.sh dfo-dev dcp
unset STUB_MISSING_ENV
check "audit fails on a missing environment" "$(is "$status" 1)"
check "audit names the missing environment" "$(says 'environment does not exist')"

run check-deploy-branch-policy.sh dfo-nope
check "audit unknown env exits 1" "$(is "$status" 1)"
run check-deploy-branch-policy.sh dfo-nope apis
check "audit unknown env with a stack exits 1" "$(is "$status" 1)"
check "audit unknown env with a stack makes no api call" "$(lacks 'gh api')"
run check-deploy-branch-policy.sh dfo-prod foundation
check "audit unknown stack exits 1" "$(is "$status" 1)"
run check-deploy-branch-policy.sh
check "audit with no env exits 1" "$(is "$status" 1)"

if [ "$failures" -eq 0 ]; then
    echo "All scenarios passed."
    exit 0
else
    echo "$failures scenario(s) failed."
    exit 1
fi
