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
# This copies those values into the repo's GitHub Environment with `gh`,
# using your existing GitHub login. It is deliberately NOT done in
# Terraform: that would need a long-lived GitHub admin credential stored in
# Secret Manager, defeating the keyless WIF design, and these values change
# only when the stacks rename something, so a one-shot script is the right
# tool.
#
# The first argument is the Terraform environment, `dfo-dev` or `dfo-prod`;
# the second is the stack. scripts/deploy-targets.sh maps that pair to the
# repo (`DevelopmentFinanceObservatory/<stack>`), the GitHub Environment
# (`dev` or `production`) and the one branch the environment admits. The
# environment must already exist with exactly that branch policy, which
# scripts/setup-github-repos.sh sets. This script checks it, refuses
# otherwise, and changes no environment's protection itself. An unknown
# environment or stack fails before anything is read or written.
#
# The stack `infra` hands this repo its own values, into the environments
# its workflows declare: the planner's WIF_PROVIDER and WIF_PLAN_SA into
# `dev-plan` (dfo-dev) or `plan` (dfo-prod), and the applier's WIF_PROVIDER
# and WIF_APPLY_SA into `dev` or `production`. It writes nothing at repo
# level, so a job that declares no environment cannot authenticate. It
# needs only foundation applied.
#
# The stack `docs` hands dfo-docs the GCP_WIF_PROVIDER and
# DOCSYNC_SERVICE_ACCOUNT that docsync.yml reads, into its `docsync`
# environment. It runs in dfo-dev only and needs only foundation applied.
#
# Run AFTER foundation and every stack the table reads are applied in that
# environment (their outputs must exist): the stack itself, and website as
# well for dcp, whose DFO_SITE_ORIGIN is the website's public origin. Every
# output is read and every environment checked before anything is written,
# so a missing one changes nothing.
#
# Usage: scripts/handoff.sh <env> <stack>
#   scripts/handoff.sh dfo-dev ai        # DevelopmentFinanceObservatory/ai, environment dev
#   scripts/handoff.sh dfo-prod apis     # DevelopmentFinanceObservatory/apis, environment production
#   scripts/handoff.sh dfo-dev infra     # DevelopmentFinanceObservatory/infra, environments dev-plan and dev
#   scripts/handoff.sh dfo-dev docs      # DevelopmentFinanceObservatory/docs, environment docsync
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

# Where the values go comes from the shared table. An unknown environment
# or stack stops here, before any gh call or Terraform read. A plain
# assignment, so a failed lookup stops the script.
targets="$(handoff_targets "$dfo_env" "$stack")" || exit 1

command -v gh >/dev/null || { echo "gh CLI not found. Install: https://cli.github.com" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in to GitHub. Run 'gh auth login'." >&2; exit 1; }

# Read one infra-derived value from a stack's Terraform state, failing loudly
# if the stack hasn't been applied (or init'd) yet. `output -json NAME` exits 1
# with nothing on stdout for a state with no outputs, where `output -raw` exits
# 0 and prints a "No outputs found" warning to stdout. Terraform stores no
# null output, so an output whose resource is off in this environment is
# missing too. deploy_values lists such rows only where the resource exists.
read_output() {
    local dir="$1" name="$2" val
    # stdin is closed so terraform cannot consume the table the caller's loop reads.
    val="$(cd "$dir" && terraform output -json "$name" 2>/dev/null </dev/null |
        jq -r 'select(. != null) | tostring')" || true
    if [ -z "$val" ]; then
        echo "Could not read output '$name' from $dir." >&2
        echo "Has the stack been applied? Try: (cd $dir && terraform init && terraform output $name)" >&2
        exit 1
    fi
    printf '%s' "$val"
}

# Read every value before writing any, into parallel arrays (bash 3.2 has no
# associative arrays), one entry per environment and value. The loops read
# from variables, not command substitutions, so a failed lookup cannot pass
# as an empty table.
echo ">> Reading dfo-infra outputs..."
repos=() envs=() kinds=() names=() vals=()
checked=""
while read -r repo env branch values_key; do
    [ -z "$repo" ] && continue
    values="$(deploy_values "$values_key" "$dfo_env")" || {
        echo "ERROR: deploy_values lists nothing for $values_key." >&2
        exit 1
    }
    echo "   -> $repo  (environment: $env; terraform env: $dfo_env)"
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
        repos+=("$repo")
        envs+=("$env")
        kinds+=("$kind")
        names+=("$name")
        vals+=("$val")
        printf '      %-24s = %s  (%s output %s)\n' "$name" "$val" "$root" "$output"
    done <<<"$values"
    checked="${checked}${repo} ${env} ${branch}"$'\n'
done <<<"$targets"
if [ "${#names[@]}" -eq 0 ]; then
    echo "ERROR: no values resolved for $stack in $dfo_env." >&2
    exit 1
fi

# Every target environment must exist with the branch policy the table
# gives it before any value lands in it. A value written to a missing
# environment would create it unrestricted.
echo ">> Checking the target environments..."
ok=true
while read -r repo env branch; do
    [ -z "$repo" ] && continue
    check_environment "$repo" "$env" "$branch" || ok=false
done <<<"$checked"
if [ "$ok" != true ]; then
    echo "ERROR: fix the environments above with scripts/setup-github-repos.sh --apply; nothing was written." >&2
    exit 1
fi

# Variables and secrets follow how the repo's workflows read them (vars.* or
# secrets.*). The secrets' values are non-sensitive identifiers, but this
# script keeps that repo's split.
i=0
while [ "$i" -lt "${#names[@]}" ]; do
    echo ">> Setting ${names[$i]} ${kinds[$i]} in '${envs[$i]}' on ${repos[$i]}..."
    case "${kinds[$i]}" in
    var) gh variable set "${names[$i]}" --env "${envs[$i]}" --repo "${repos[$i]}" --body "${vals[$i]}" ;;
    secret) gh secret set "${names[$i]}" --env "${envs[$i]}" --repo "${repos[$i]}" --body "${vals[$i]}" ;;
    esac
    i=$((i + 1))
done

echo ""
echo "Done. Wrote ${#names[@]} values for $stack in $dfo_env:"
while read -r repo env branch; do
    [ -z "$repo" ] && continue
    echo "   $repo '$env': gh variable list --env $env --repo $repo && gh secret list --env $env --repo $repo"
done <<<"$checked"
