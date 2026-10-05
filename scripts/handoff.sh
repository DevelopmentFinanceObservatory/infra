#!/usr/bin/env bash
# Hand dfo-infra's Terraform outputs to a service repo's GitHub Environment.
#
# A service repo's deploy workflow authenticates to GCP over WIF and pushes
# image-only updates to the Cloud Run services and Jobs that dfo-infra owns.
# Every value it reads from its GitHub Environment (project, region,
# registry, service and Job names, the WIF provider and deployer account)
# is a Terraform output, and this script is the only thing that sets them.
# scripts/deploy-targets.sh's deploy_values holds the one table of which
# variable or secret comes from which stack's output.
#
# This copies those values into the service repo's GitHub Environment with
# `gh`, using your existing GitHub login. It is deliberately NOT done in
# Terraform: that would need a long-lived GitHub admin credential stored in
# Secret Manager, defeating the keyless WIF design, and these values change
# only when the stacks rename something, so a one-shot script is the right
# tool. The same reasoning covers the environment's deployment branch policy
# this script also sets: the WIF binding already pins the target
# environment's subject to one git ref (infra/modules/github-deployer's
# repo_env_ref mode), but that pin lives in dfo-infra's Terraform state and
# GCP's IAM policy, which GitHub has no visibility into. The deployment
# branch policy is a second, independent check that lives on the
# environment itself, where this Terraform can't assert it, and it too
# needs a GitHub admin credential this script borrows from your login
# rather than storing.
#
# The first argument is the Terraform environment, `dfo-dev` or `dfo-prod`;
# the second is the stack. scripts/deploy-targets.sh maps that pair to the
# service repo (`ONEcampaign/dfo-<stack>` in dev,
# `DevelopmentFinanceObservatory/<stack>` in prod), the GitHub Environment
# (`dev`, `staging` for the dev website, or `production`), and the one
# deploy branch the environment's policy admits. The branch is the value
# pinned in that file, not the repo's current default branch on GitHub; see
# the file for why. An unknown environment or stack fails before anything is
# read or written.
#
# The stack `infra` hands this repo its own values instead: WIF_PROVIDER,
# WIF_PLAN_SA and WIF_APPLY_SA, which the plan and apply workflows read, go
# to the env's infra repo (`ONEcampaign/dfo-infra` or
# `DevelopmentFinanceObservatory/infra`) as repo-level variables, with no
# environment or branch policy. It needs only foundation applied.
#
# Run AFTER foundation and every stack the table reads are applied in that
# environment (their outputs must exist): the stack itself, and apis as well
# for dcp, whose DFO_APIS_BASE_URL is the apis service URL. Every output is
# read before anything is written, so a missing one changes nothing.
#
# Usage: scripts/handoff.sh <env> <stack>
#   scripts/handoff.sh dfo-dev ai        # ONEcampaign/dfo-ai, environment dev, branch dev
#   scripts/handoff.sh dfo-dev website   # ONEcampaign/dfo-website, environment staging, branch staging
#   scripts/handoff.sh dfo-prod apis     # DevelopmentFinanceObservatory/apis, environment production, branch main
#   scripts/handoff.sh dfo-prod infra    # DevelopmentFinanceObservatory/infra, repo-level variables
set -euo pipefail

# The usage text lives once, in the "Usage:" block of the header comment
# above — printed verbatim (with the `# ` comment marker stripped) rather
# than duplicated into a string literal here, so `--help` output can't
# drift from it.
print_usage() {
    sed -n '/^# Usage:/,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
}

# Handle -h/--help, and reject any other option-looking argument, before
# any positional is assigned: this runs ahead of the gh checks, API calls,
# and Terraform reads below, so `--help` in any position (not just first)
# can never be mistaken for a positional value like `stack` and used to
# mutate an environment.
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
if [ $# -ne 2 ]; then
    echo "Expected 2 arguments: env stack." >&2
    print_usage >&2
    exit 1
fi

dfo_env="$1"
stack="$2"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091 # dynamic paths; both files live beside this script
source "$repo_root/scripts/deploy-targets.sh"
# shellcheck disable=SC1091
source "$repo_root/scripts/github-environment.sh"

# The repo, GitHub Environment and deploy branch all come from the shared
# table. An unknown environment or stack stops here, before any
# gh call or Terraform read. An empty env means repo-level values (infra).
load_handoff_target "$dfo_env" "$stack" || exit 1
repo="$DEPLOY_REPO"
env="$DEPLOY_GH_ENV"
branch="$DEPLOY_BRANCH"
values="$(deploy_values "$stack")"

command -v gh >/dev/null || { echo "gh CLI not found. Install: https://cli.github.com" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in to GitHub. Run 'gh auth login'." >&2; exit 1; }

# Read one infra-derived value from a stack's Terraform state, failing loudly
# if the stack hasn't been applied (or init'd) yet.
read_output() {
    local dir="$1" name="$2" val
    # stdin is closed so terraform cannot consume the table the caller's loop reads.
    val="$(cd "$dir" && terraform output -raw "$name" 2>/dev/null </dev/null)" || true
    if [ -z "$val" ]; then
        echo "Could not read output '$name' from $dir." >&2
        echo "Has the stack been applied? Try: (cd $dir && terraform init && terraform output $name)" >&2
        exit 1
    fi
    printf '%s' "$val"
}

# Read every value before writing any, into parallel arrays (bash 3.2 has no
# associative arrays). The loop reads from a variable, not a command
# substitution, so a deploy_values failure cannot pass as an empty table.
echo ">> Reading dfo-infra outputs..."
kinds=() names=() vals=()
while read -r kind name root output; do
    [ -z "$kind" ] && continue
    case "$kind" in
    var | secret) ;;
    *)
        echo "ERROR: unknown kind '$kind' for $name in deploy_values." >&2
        exit 1
        ;;
    esac
    # A plain assignment, so a failed read stops the script under errexit.
    val="$(read_output "$repo_root/$(deploy_tf_dir "$dfo_env" "$root")" "$output")"
    kinds+=("$kind")
    names+=("$name")
    vals+=("$val")
    printf '   %-24s = %s  (%s output %s)\n' "$name" "$val" "$root" "$output"
done <<<"$values"
if [ "${#names[@]}" -eq 0 ]; then
    echo "ERROR: deploy_values listed nothing for $stack." >&2
    exit 1
fi
if [ -n "$env" ]; then
    echo "   -> $repo  (environment: $env, deploy branch: $branch; terraform env: $dfo_env)"
    # Create the environment if needed and restrict it to the deploy branch,
    # before any value is written. scripts/github-environment.sh documents
    # the guard against environments with other protection rules.
    converge_branch_policy "$repo" "$env" "$branch" || exit 1
    scope=(--env "$env")
else
    echo "   -> $repo  (repo-level; terraform env: $dfo_env)"
    scope=()
fi

# Variables and secrets follow how the service repo's workflows read them
# (vars.* or secrets.*). The secrets' values are non-sensitive identifiers,
# but this script keeps that repo's split.
i=0
while [ "$i" -lt "${#names[@]}" ]; do
    echo ">> Setting ${names[$i]} ${kinds[$i]}..."
    case "${kinds[$i]}" in
    # The +-expansion keeps an empty scope from tripping bash 3.2's nounset.
    var) gh variable set "${names[$i]}" ${scope[@]+"${scope[@]}"} --repo "$repo" --body "${vals[$i]}" ;;
    secret) gh secret set "${names[$i]}" ${scope[@]+"${scope[@]}"} --repo "$repo" --body "${vals[$i]}" ;;
    esac
    i=$((i + 1))
done

echo ""
if [ -n "$env" ]; then
    echo "Done. $repo '$env' environment now has ${#names[@]} values (${names[*]}),"
    echo "and a deployment branch policy restricted to '$branch'."
    echo "Verify: gh variable list --env $env --repo $repo && gh secret list --env $env --repo $repo"
    echo "   && scripts/check-deploy-branch-policy.sh $dfo_env $stack"
else
    echo "Done. $repo now has ${#names[@]} repo-level values (${names[*]})."
    echo "Verify: gh variable list --repo $repo"
fi
