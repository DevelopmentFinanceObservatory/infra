# shellcheck shell=bash
# GitHub Environment helpers shared by the scripts that read or write
# environments. Sourced; targets bash 3.2.
#
# scripts/setup-github-repos.sh is the one writer of an environment's
# protection: it calls converge_environment. scripts/handoff.sh and
# scripts/setup-github-apps.sh only write values, after check_environment
# has confirmed the environment exists with the branch policy
# scripts/deploy-targets.sh gives it. scripts/check-deploy-branch-policy.sh
# audits with check_environment too.
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

# The environment's protection as one comparable line, from the JSON of an
# environment GET:
#   reviewers=<type:id,...> self=<bool> wait=<n> branches=<none|protected|custom>
ENVIRONMENT_STATE_JQ='
"reviewers=" + ([.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]? | "\(.type):\(.reviewer.id)"] | sort | join(","))
+ " self=" + ([.protection_rules[]? | select(.type == "required_reviewers") | .prevent_self_review // false] | any | tostring)
+ " wait=" + ([.protection_rules[]? | select(.type == "wait_timer") | .wait_timer // 0] | add // 0 | tostring)
+ " branches=" + (if .deployment_branch_policy == null then "none"
    elif .deployment_branch_policy.custom_branch_policies then "custom"
    else "protected" end)'

# check_environment <owner/repo> <environment> <branch|->: prints one PASS or
# FAIL line saying what it found, and returns 1 on FAIL or on any error
# reaching the API. With a branch, the environment must admit exactly
# {name=<branch>, type=branch}; with `-`, it must have no branch policy.
#
# The branch-policies listing 404s both when the environment does not exist
# and when it exists without custom policies, so the environment itself is
# read first.
check_environment() {
    local repo="$1" env="$2" branch="$3" err env_json dbp policies expected
    err="$(mktemp)"
    if ! env_json="$(gh api "repos/$repo/environments/$env" 2>"$err")"; then
        if grep -q "HTTP 404" "$err"; then
            echo "FAIL  $repo ($env): environment does not exist. Run scripts/setup-github-repos.sh."
        else
            echo "FAIL  $repo ($env): could not read the environment:"
            sed 's/^/        /' "$err"
        fi
        rm -f "$err"
        return 1
    fi
    dbp="$(printf '%s' "$env_json" | jq -r 'if .deployment_branch_policy == null then "none"
        elif .deployment_branch_policy.custom_branch_policies then "custom" else "protected" end')"

    if [ "$branch" = - ]; then
        rm -f "$err"
        if [ "$dbp" = none ]; then
            echo "PASS  $repo ($env): no branch policy, as intended."
            return 0
        fi
        echo "FAIL  $repo ($env): expected no branch policy, found '$dbp'."
        return 1
    fi
    case "$dbp" in
    none)
        rm -f "$err"
        echo "FAIL  $repo ($env): unrestricted; deployment_branch_policy is null, so every branch and tag may deploy."
        return 1
        ;;
    protected)
        rm -f "$err"
        echo "FAIL  $repo ($env): restricted to GitHub's protected branches, not to the named '$branch' branch."
        return 1
        ;;
    esac

    if ! policies="$(gh api --paginate "repos/$repo/environments/$env/deployment-branch-policies" \
        --jq '.branch_policies[] | [.name, (.type // "branch")] | @tsv' 2>"$err")"; then
        echo "FAIL  $repo ($env): could not read deployment branch policies:"
        sed 's/^/        /' "$err"
        rm -f "$err"
        return 1
    fi
    rm -f "$err"
    expected="$(printf '%s\t%s' "$branch" branch)"
    if [ "$policies" = "$expected" ]; then
        echo "PASS  $repo ($env): restricted to '$branch'."
        return 0
    fi
    echo "FAIL  $repo ($env): expected exactly {name=$branch, type=branch}, found:"
    if [ -z "$policies" ]; then
        echo "        (none; every branch is rejected)"
    else
        printf '%s\n' "$policies" | sed 's/^/        /'
    fi
    return 1
}

# converge_environment <owner/repo> <environment> <branch|-> <team-id|->
# leaves the environment existing with exactly this protection: required
# reviewers the one team (self-review allowed) or none, no wait timer, and
# a deployment branch policy of exactly {name=<branch>, type=branch}, or
# none for `-`. The PUT sends every protection setting, so nothing it omits
# survives. It skips the PUT when the environment already matches, and
# reads the result back after a real run.
converge_environment() {
    local repo="$1" env="$2" branch="$3" team="$4"
    local env_path="repos/$repo/environments/$env"
    local policies_path="$env_path/deployment-branch-policies"
    local err env_json current="absent" want body policies
    local keep_id="" others="" id name type
    err="$(mktemp)"

    want="reviewers=$([ "$team" = - ] || printf 'Team:%s' "$team") self=false wait=0 branches=$([ "$branch" = - ] && echo none || echo custom)"
    if env_json="$(gh api "$env_path" 2>"$err")"; then
        current="$(printf '%s' "$env_json" | jq -r "$ENVIRONMENT_STATE_JQ")"
    elif ! grep -q "HTTP 404" "$err"; then
        cat "$err" >&2
        rm -f "$err"
        return 1
    fi

    if [ "$current" = "$want" ]; then
        echo ">> '$env' on $repo already has $want."
    else
        echo ">> Setting '$env' on $repo: $current -> $want"
        body="$(jq -n --arg team "$team" --arg branch "$branch" '{
            wait_timer: 0,
            prevent_self_review: false,
            reviewers: (if $team == "-" then [] else [{type: "Team", id: ($team | tonumber)}] end),
            deployment_branch_policy: (if $branch == "-" then null
                else {protected_branches: false, custom_branch_policies: true} end)
        }')"
        printf '%s' "$body" >"$err.body"
        gh_write api --method PUT "$env_path" --input "$err.body" --silent || { rm -f "$err" "$err.body"; return 1; }
        rm -f "$err.body"
    fi

    if [ "$branch" != - ]; then
        # Create before delete, so the set is never empty: with custom
        # policies on, an empty set rejects every branch. A tag policy can
        # share the branch's name, so type is checked with name. The type
        # field is absent on policies older than tag policies.
        #
        # A dry run against an environment that does not exist yet, or has
        # no custom policies yet, lists nothing, since the PUT was printed.
        if ! policies="$(gh api --paginate "$policies_path" --jq '.branch_policies[] | [.id, .name, (.type // "branch")] | @tsv' 2>"$err")"; then
            if grep -q "HTTP 404" "$err" && { [ "${GH_DRY_RUN:-false}" = true ] || [ "$current" = absent ]; }; then
                policies=""
            else
                echo "ERROR: could not list '$env' environment's deployment branch policies on $repo:" >&2
                cat "$err" >&2
                rm -f "$err"
                return 1
            fi
        fi
        while IFS=$'\t' read -r id name type; do
            [ -z "$id" ] && continue
            if [ "$name" = "$branch" ] && [ "$type" = branch ] && [ -z "$keep_id" ]; then
                keep_id="$id"
            else
                others="${others}${id}"$'\t'"${name}"$'\t'"${type}"$'\n'
            fi
        done <<<"$policies"
        if [ -z "$keep_id" ]; then
            echo ">> Adding '$branch' to '$env' environment's branch policy on $repo..."
            gh_write api --method POST "$policies_path" -f name="$branch" -f type=branch --silent || { rm -f "$err"; return 1; }
        fi
        while IFS=$'\t' read -r id name type; do
            [ -z "$id" ] && continue
            echo ">> Removing $type policy '$name' (id $id) from '$env' on $repo; only '$branch' may use it."
            gh_write api --method DELETE "$policies_path/$id" --silent || { rm -f "$err"; return 1; }
        done <<<"$others"
    fi
    rm -f "$err"

    [ "${GH_DRY_RUN:-false}" = true ] && return 0
    current="$(gh api "$env_path" --jq "$ENVIRONMENT_STATE_JQ")" || return 1
    if [ "$current" != "$want" ]; then
        echo "ERROR: '$env' on $repo reads back as '$current', expected '$want'." >&2
        return 1
    fi
    check_environment "$repo" "$env" "$branch" >/dev/null || {
        check_environment "$repo" "$env" "$branch" >&2
        return 1
    }
}
