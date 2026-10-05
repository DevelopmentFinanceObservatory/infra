#!/usr/bin/env bash
# Converge the `main` ruleset on each DevelopmentFinanceObservatory repo and
# give the `release` team write on it, so an approval from a release member
# is what merges a sync PR. An approval counts only from someone with write,
# and no other team holds it.
#
# Each repo's ruleset is named `main`, targets the default branch, and has
# no bypass actors, so org owners are held to it too. It sets:
#   - a pull request before merging, with one approval, approvals dismissed
#     by a new push, the last push approved by someone other than its
#     pusher, and merge commits only. A merge of a head whose only parent is
#     main's head keeps the guarded commit and its tree in main's history.
#   - required status checks with the branch up to date: `sync-guard` in
#     every repo, and in infra also `terraform fmt check` and `Prod changed
#     stacks planned`. No other CI is required, since prod PR CI skips by
#     design and GitHub counts a skipped required check as passing.
#   - no deletion of main and no force push to it.
#
# --guard-app-id pins `sync-guard` to that App as its source, so a check of
# the same name from anything else does not count. GitHub accepts an App as
# a check's source only after it has posted a check run in the repo, so run
# the script without it first, then again with dfo-release's app id once the
# guard has run in every repo. A run without it leaves `sync-guard` open to
# any source.
#
# Running it again converges: an existing `main` ruleset is replaced, never
# duplicated.
#
# Usage: scripts/setup-prod-rulesets.sh [options]
#   scripts/setup-prod-rulesets.sh --dry-run
#   scripts/setup-prod-rulesets.sh --guard-app-id 5164144
#
#   --guard-app-id ID   pin sync-guard to the App with this numeric id
#   --dry-run           run the reads and print every gh write without making it
#   -h, --help          print this help
set -euo pipefail

print_usage() {
    sed -n '/^# Usage:/,/^#   -h, --help/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

guard_app_id="" dry_run=false
while [ "$#" -gt 0 ]; do
    case "$1" in
    --guard-app-id)
        guard_app_id="${2:-}"
        shift
        ;;
    --dry-run) dry_run=true ;;
    -h | --help)
        print_usage
        exit 0
        ;;
    *)
        echo "Unrecognized argument: $1" >&2
        print_usage >&2
        exit 1
        ;;
    esac
    shift
done
if [ -n "$guard_app_id" ] && ! [[ "$guard_app_id" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --guard-app-id takes a numeric app id, got '$guard_app_id'." >&2
    exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091 # dynamic paths; both files live beside this script
source "$repo_root/scripts/deploy-targets.sh"
# shellcheck disable=SC1091
source "$repo_root/scripts/github-environment.sh"
if [ "$dry_run" = true ]; then
    export GH_DRY_RUN=true
    echo ">> Dry run: reads run, writes are printed and not made."
fi

owner=DevelopmentFinanceObservatory
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ruleset_json <name> prints the ruleset for one repo.
ruleset_json() {
    local checks='["sync-guard"]'
    if [ "$1" = infra ]; then
        checks='["sync-guard", "terraform fmt check", "Prod changed stacks planned"]'
    fi
    jq -n --argjson checks "$checks" --arg app "$guard_app_id" '{
        name: "main",
        target: "branch",
        enforcement: "active",
        bypass_actors: [],
        conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
        rules: [
            {type: "deletion"},
            {type: "non_fast_forward"},
            {type: "pull_request", parameters: {
                required_approving_review_count: 1,
                dismiss_stale_reviews_on_push: true,
                require_last_push_approval: true,
                require_code_owner_review: false,
                required_review_thread_resolution: false,
                allowed_merge_methods: ["merge"]
            }},
            {type: "required_status_checks", parameters: {
                strict_required_status_checks_policy: true,
                do_not_enforce_on_create: false,
                required_status_checks: [$checks[] | {context: .}
                    + (if . == "sync-guard" and $app != "" then {integration_id: ($app | tonumber)} else {} end)]
            }}
        ]
    }'
}

covered=0
for name in $(org_repos dfo-prod); do
    slug="$(org_repo dfo-prod "$name")"
    echo ">> Giving the release team write on $slug..."
    gh_write api --method PUT "orgs/$owner/teams/release/repos/$slug" -f permission=push --silent

    ruleset_json "$name" >"$work/$name.json"
    id="$(gh api "repos/$slug/rulesets" --jq '.[] | select(.name == "main") | .id')"
    if [ -n "$id" ]; then
        echo ">> Replacing the main ruleset ($id) on $slug..."
        gh_write api --method PUT "repos/$slug/rulesets/$id" --input "$work/$name.json" --silent
    else
        echo ">> Creating the main ruleset on $slug..."
        gh_write api --method POST "repos/$slug/rulesets" --input "$work/$name.json" --silent
    fi
    if [ "$dry_run" = true ]; then
        sed 's/^/   /' "$work/$name.json"
    fi
    covered=$((covered + 1))
done

[ "$covered" -eq 10 ] || {
    echo "ERROR: expected 10 repos, covered $covered." >&2
    exit 1
}
if [ -n "$guard_app_id" ]; then
    echo "Done. $covered rulesets require sync-guard from app $guard_app_id."
else
    echo "Done. $covered rulesets require sync-guard from any source; run again with --guard-app-id once the guard has run in every repo."
fi
