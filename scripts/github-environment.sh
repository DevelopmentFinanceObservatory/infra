# shellcheck shell=bash
# GitHub Environment helpers shared by scripts/handoff.sh and
# scripts/setup-github-apps.sh, so both create environments and set their
# deployment branch policies the same way. Sourced; targets bash 3.2.
#
# Every write goes through gh_write. With GH_DRY_RUN=true it prints the call
# and makes none; reads still run, so a dry run reports the writes a real
# run would make against the current state.
#
# The functions return 1 on failure and never exit. Bash ignores errexit
# inside a function called from an `||` list, so every write here checks
# its own status.

# gh_write <gh args...>: runs gh, or prints the call under GH_DRY_RUN=true.
# A caller that feeds a secret on stdin passes its path as GH_STDIN_FROM so
# the dry-run line names the file, never its contents.
gh_write() {
    if [ "${GH_DRY_RUN:-false}" = true ]; then
        printf 'DRY-RUN: gh'
        printf ' %q' "$@"
        if [ -n "${GH_STDIN_FROM:-}" ]; then printf ' < %q' "$GH_STDIN_FROM"; fi
        printf '\n'
        return 0
    fi
    if [ -n "${GH_STDIN_FROM:-}" ]; then
        gh "$@" <"$GH_STDIN_FROM"
    else
        gh "$@"
    fi
}

# converge_branch_policy <owner/repo> <environment> <branch> creates the
# environment if it does not exist and leaves its deployment branch policy
# set to exactly {name=<branch>, type=branch}.
#
# It refuses an environment that already carries a protection rule other
# than a branch_policy (required reviewers, a wait timer, self-review
# prevention). The environment-update PUT accepts those same settings, and
# GitHub does not document whether omitting them on a PUT leaves them alone
# or clears them. A 404 on the first read means the environment does not
# exist yet, and the PUT creates it. A lone branch_policy rule is this
# function's own past run (enabling custom_branch_policies creates that
# rule), so it does not trip the guard.
converge_branch_policy() {
    local repo="$1" env="$2" branch="$3"
    local env_path="repos/$repo/environments/$env"
    local policies_path="$env_path/deployment-branch-policies"
    local err env_json foreign_rules custom_enabled=false policies
    local keep_id="" others="" id name type final expected
    err="$(mktemp)"

    if env_json="$(gh api "$env_path" 2>"$err")"; then
        foreign_rules="$(printf '%s' "$env_json" |
            jq -r '[.protection_rules[]?.type | select(. != "branch_policy")] | join(", ")')"
        if [ -n "$foreign_rules" ]; then
            echo "ERROR: '$env' environment on $repo already has protection rule(s) this script must not risk clobbering: $foreign_rules." >&2
            echo "Set the deployment branch policy on this environment by hand instead." >&2
            rm -f "$err"
            return 1
        fi
        custom_enabled="$(printf '%s' "$env_json" | jq -r '.deployment_branch_policy.custom_branch_policies // false')"
    elif ! grep -q "HTTP 404" "$err"; then
        cat "$err" >&2
        rm -f "$err"
        return 1
    fi

    # Skip the PUT when custom policies are on already, so a rerun does not
    # resend protected_branches and custom_branch_policies, which GitHub does
    # not document as leaving the environment's other settings untouched.
    if [ "$custom_enabled" = "true" ]; then
        echo ">> '$env' environment on $repo already has custom branch policies enabled."
    else
        echo ">> Enabling custom deployment branch policies on '$env' environment ($repo)..."
        gh_write api --method PUT "$env_path" \
            -F 'deployment_branch_policy[protected_branches]=false' \
            -F 'deployment_branch_policy[custom_branch_policies]=true' \
            --silent || { rm -f "$err"; return 1; }
    fi

    # Create before delete, so the set is never empty: with custom policies
    # on, an empty set rejects every branch. A tag policy can share the
    # branch's name, so type is checked with name. The type field is absent
    # on policies older than tag policies, which are branch policies.
    #
    # The listing is a plain assignment so a failed read stops here. Fed to
    # the loop through a command substitution in a here-string, it would
    # read as zero existing policies.
    #
    # A dry run against an environment that does not exist yet lists
    # nothing, since the PUT above was only printed.
    if ! policies="$(gh api --paginate "$policies_path" --jq '.branch_policies[] | [.id, .name, (.type // "branch")] | @tsv' 2>"$err")"; then
        if [ "${GH_DRY_RUN:-false}" = true ] && grep -q "HTTP 404" "$err"; then
            policies=""
        else
            echo "ERROR: could not list '$env' environment's deployment branch policies on $repo before converging:" >&2
            cat "$err" >&2
            rm -f "$err"
            return 1
        fi
    fi
    rm -f "$err"

    while IFS=$'\t' read -r id name type; do
        [ -z "$id" ] && continue
        if [ "$name" = "$branch" ] && [ "$type" = "branch" ] && [ -z "$keep_id" ]; then
            keep_id="$id"
        else
            others="${others}${id}"$'\t'"${name}"$'\t'"${type}"$'\n'
        fi
    done <<<"$policies"

    if [ -n "$keep_id" ]; then
        echo ">> '$branch' branch policy already present on '$env' environment ($repo)."
    else
        echo ">> Adding '$branch' to the deployment branch policy on '$env' environment ($repo)..."
        gh_write api --method POST "$policies_path" -f name="$branch" -f type=branch --silent || return 1
    fi

    # Any other policy, a different branch or a same-named tag, would let
    # another ref run jobs in this environment.
    while IFS=$'\t' read -r id name type; do
        [ -z "$id" ] && continue
        echo ">> Removing deployment $type policy '$name' (id $id) from '$env' environment on $repo; only the '$branch' branch may use it."
        gh_write api --method DELETE "$policies_path/$id" --silent || return 1
    done <<<"$others"

    # A dry run changed nothing, so there is nothing to verify.
    [ "${GH_DRY_RUN:-false}" = true ] && return 0
    final="$(gh api --paginate "$policies_path" --jq '.branch_policies[] | [.name, (.type // "branch")] | @tsv')" || return 1
    expected="$(printf '%s\t%s' "$branch" branch)"
    if [ "$final" != "$expected" ]; then
        echo "ERROR: after converging, '$env' environment's deployment branch policies on $repo are not exactly {name=$branch, type=branch}:" >&2
        printf '%s\n' "$final" >&2
        return 1
    fi
}
