#!/usr/bin/env bash
# Audit a service repo's deployment branch policy — read-only, and runnable
# by anyone with read access to these repos and no Terraform state, unlike
# handoff.sh, which needs both admin writes and applied stacks.
#
# The WIF binding for each deployer service account already pins both its
# GitHub Environment and the git ref that may mint its OIDC token (see
# infra/modules/github-deployer's repo_env_ref mode) — that binding is what
# actually enforces the boundary. The environment's deployment branch
# policy is a second, independent check in front of it: set and owned
# entirely on GitHub, in the service repo, outside anything dfo-infra's
# Terraform can assert. This script checks that policy directly against the
# GitHub API, because the two disagreeing fails the next deploy at the auth
# step rather than anything here reporting the mismatch.
#
# The first argument is the Terraform environment, `dfo-dev` or `dfo-prod`.
# With no stack, it checks every deployer target scripts/deploy-targets.sh
# lists for that environment: ai, apis, dcp and website. dcp matters most: its
# Environment holds the GitHub App key that opens image-pin PRs here, so an
# unrestricted policy there removes the boundary without anything else
# reporting it. With a stack, it checks that one target. Repo, GitHub
# Environment and expected branch all come from the same table handoff.sh
# writes from. An unknown environment or stack exits 1.
#
# Usage: scripts/check-deploy-branch-policy.sh <env> [stack]
#   scripts/check-deploy-branch-policy.sh dfo-dev            # every dev target
#   scripts/check-deploy-branch-policy.sh dfo-prod apis      # DevelopmentFinanceObservatory/apis, environment production
# Exit:  0 = every checked target has exactly its expected branch policy,
#        1 = at least one target doesn't, or a check couldn't complete.
set -euo pipefail

# The usage text lives once, in the "Usage:"/"Exit:" block of the header
# comment above — printed verbatim (with the `# ` comment marker stripped)
# rather than duplicated into a string literal here, so `--help` output
# can't drift from it.
print_usage() {
    sed -n '/^# Usage:/,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
}

# Handle -h/--help, and reject any other option-looking argument, before
# any positional is assigned or any gh call is made, so `--help` in any
# position can't be mistaken for a positional value.
for arg in "$@"; do
    case "$arg" in
    -h | --help)
        print_usage
        exit 0
        ;;
    -*)
        echo "Unrecognized option: $arg" >&2
        print_usage >&2
        exit 1
        ;;
    esac
done
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Expected 1 or 2 arguments: env [stack]." >&2
    print_usage >&2
    exit 1
fi

# shellcheck disable=SC1091 # dynamic path; deploy-targets.sh lives beside this script
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy-targets.sh"

command -v gh >/dev/null || { echo "gh CLI not found. Install: https://cli.github.com" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in to GitHub. Run 'gh auth login'." >&2; exit 1; }

err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

# The branch-policies listing 404s in two situations that mean opposite
# things: the environment doesn't exist (nothing configured), or it exists
# with custom_branch_policies off (no restriction at all — every branch and
# tag may deploy, or GitHub's generic "protected branches" gate applies
# instead of a named branch). A follow-up GET on the environment itself
# tells these apart; called only after the listing has already 404'd.
report_unlisted_policy_state() {
    local repo="$1" env="$2" branch="$3" env_json dbp_null protected_branches

    if ! env_json="$(gh api "repos/$repo/environments/$env" 2>"$err_file")"; then
        if grep -q "HTTP 404" "$err_file"; then
            echo "FAIL  $repo ($env): environment does not exist — nothing is configured, and a workflow that references environment: $env can cause GitHub to create it unrestricted."
        else
            echo "FAIL  $repo ($env): could not determine the deployment branch policy:"
            sed 's/^/        /' "$err_file"
        fi
        return 1
    fi

    dbp_null="$(printf '%s' "$env_json" | jq -r '.deployment_branch_policy == null')"
    if [ "$dbp_null" = "true" ]; then
        echo "FAIL  $repo ($env): unrestricted — deployment_branch_policy is null, so every branch and tag may deploy."
        return 1
    fi

    protected_branches="$(printf '%s' "$env_json" | jq -r '.deployment_branch_policy.protected_branches // false')"
    if [ "$protected_branches" = "true" ]; then
        echo "FAIL  $repo ($env): restricted to GitHub's protected branches, not to the named '$branch' branch."
        return 1
    fi

    echo "FAIL  $repo ($env): could not determine the deployment branch policy (unrecognized environment state)."
    return 1
}

# Check one target's deployment branch policy, printing a PASS/FAIL line
# that states what was found. Returns non-zero on FAIL (or on any error
# reaching the API), so the caller tracks overall status without exiting
# per-target itself.
check_target() {
    local dfo_env="$1" stack="$2" repo env branch

    load_deploy_target "$dfo_env" "$stack" || return 1
    repo="$DEPLOY_REPO"
    env="$DEPLOY_GH_ENV"
    branch="$DEPLOY_BRANCH"

    local policies
    if ! policies="$(gh api --paginate "repos/$repo/environments/$env/deployment-branch-policies" \
            --jq '.branch_policies[] | [.name, (.type // "branch")] | @tsv' 2>"$err_file")"; then
        if grep -q "HTTP 404" "$err_file"; then
            report_unlisted_policy_state "$repo" "$env" "$branch"
        else
            echo "FAIL  $repo ($env): could not read deployment branch policies:"
            sed 's/^/        /' "$err_file"
        fi
        return 1
    fi

    local expected
    expected="$(printf '%s\t%s' "$branch" branch)"
    if [ "$policies" = "$expected" ]; then
        echo "PASS  $repo ($env): deploys restricted to '$branch'."
        return 0
    fi

    echo "FAIL  $repo ($env): expected exactly {name=$branch, type=branch}, found:"
    if [ -z "$policies" ]; then
        echo "        (none — every branch is currently rejected)"
    else
        printf '        %s\n' "$policies"
    fi
    return 1
}

status=0
dfo_env="$1"

if [ $# -eq 1 ]; then
    # An unknown environment has no stack list; fail it here rather than loop
    # over nothing and report success.
    if ! stacks="$(deploy_stacks "$dfo_env")"; then
        echo "ERROR: unknown environment '$dfo_env' (expected dfo-dev or dfo-prod)." >&2
        exit 1
    fi
    for stack in $stacks; do
        check_target "$dfo_env" "$stack" || status=1
    done
else
    check_target "$dfo_env" "$2" || status=1
fi

exit "$status"
