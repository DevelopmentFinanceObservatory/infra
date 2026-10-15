#!/usr/bin/env bash
# Audit a service repo's deployment branch policy. Read-only, and runnable
# by anyone with read access to these repos and no Terraform state, unlike
# handoff.sh, which needs both admin writes and applied stacks.
#
# The WIF binding for each deployer service account pins both its GitHub
# Environment and the git ref that may mint its OIDC token (see
# infra/modules/github-deployer's repo_env_ref mode), and that binding
# enforces the boundary. The environment's deployment branch policy is a
# second, independent check in front of it, set on GitHub by
# scripts/setup-github-repos.sh, outside anything dfo-infra's Terraform can
# assert. This script checks that policy against the GitHub API, because
# the two disagreeing fails the next deploy at the auth step with nothing
# else reporting the mismatch.
#
# The first argument is the Terraform environment, `dfo-dev` or `dfo-prod`.
# With no stack, it checks every deploy target scripts/deploy-targets.sh
# lists for that environment: ai, apis, dcp and website. dcp matters most:
# its `dev` environment holds the dfo-pin App key that opens image-pin PRs
# on infra, so an unrestricted policy there removes the boundary with
# nothing else reporting it. With a stack, it checks that one target. An
# unknown environment or stack exits 1.
#
# Usage: scripts/check-deploy-branch-policy.sh <env> [stack]
#   scripts/check-deploy-branch-policy.sh dfo-dev            # every dev target, environment dev
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

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/github-environment.sh"

command -v gh >/dev/null || { echo "gh CLI not found. Install: https://cli.github.com" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in to GitHub. Run 'gh auth login'." >&2; exit 1; }

# check_target <env> <stack> prints a PASS or FAIL line for one deploy
# target and returns 1 on FAIL, so the caller tracks overall status.
check_target() {
    load_deploy_target "$1" "$2" || return 1
    check_environment "$DEPLOY_REPO" "$DEPLOY_GH_ENV" "$DEPLOY_BRANCH"
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
