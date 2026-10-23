#!/usr/bin/env bash
# Converge the GitHub settings of every DevelopmentFinanceObservatory repo
# that scripts/deploy-targets.sh lists. Dry run by default: every read runs
# and every write is printed. --apply makes the writes, then reads each
# setting back and fails on any that did not take.
#
# Per repo, in this order across all repos:
#   1. The `release` team holds write, since a PR approval counts only from
#      someone with write, and environment reviewers need read.
#   2. The `main` ruleset targets refs/heads/main by name, so step 6 moving
#      a default branch to `dev` leaves it on `main`.
#      It needs one approval, dismisses approvals on a new push, needs the
#      last push approved by someone else, allows merge commits only, and
#      lets MAIN_BYPASS_USER bypass it through a pull request. infra's also
#      requires `terraform fmt check` and `Prod changed stacks planned`,
#      not strict, since plan-prod.yml plans the merge ref.
#   3. The `dev` ruleset, from dev_ruleset below. infra's needs no approval
#      and requires `Changed stacks planned`, `terraform fmt check` and
#      `Prod pin placeholder unchanged`, so dcp's dev pin PRs auto-merge
#      once planned. dcp's needs a pull request, no approval, and its
#      `checks / prototypes` check, and allows merge commits only.
#      dev_ruleset sets the other repos' rules.
#   4. Every environment in REPO_ENVIRONMENTS, with exactly its branch
#      policy and reviewers (scripts/github-environment.sh,
#      converge_environment).
#   5. The `sync`, `sync-guard` and `staging` environments are deleted where
#      present. sync and sync-guard held the dfo-release and dfo-reader keys
#      and admitted `main` with no reviewers.
#   6. The default branch, from default_branch in scripts/deploy-targets.sh.
#      A repo whose default would be `dev` must have a `dev` branch first.
#      infra also allows auto-merge, which dcp's dev pin PRs arm.
#   7. infra's repo-level WIF_PROVIDER, WIF_PLAN_SA and WIF_APPLY_SA are
#      deleted once every infra environment holds its own (scripts/handoff.sh
#      <env> infra writes them). Until then they stay and the run says so,
#      because a job reading them would lose its credentials.
#
# Every repo, and the `dev` branch of each repo defaulting to `dev`, must
# exist before --apply writes anything. A dry run reports what is missing
# and skips a missing repo.
#
# Required checks are pinned to GitHub Actions (app id 15368). That stops a
# commit status or a check run of the same name from any other App. It does
# not stop a workflow the PR's own head adds from posting a check run of the
# same name, since that run also comes from GitHub Actions. On infra `main`,
# the boundary is the `production` environment's `release` approval before
# any apply. A reviewer approves only after the PR's `Terraform Plan (prod)`
# run succeeded for the merged head.
#
# Usage: scripts/setup-github-repos.sh [--apply]
#   scripts/setup-github-repos.sh            # dry run
#   scripts/setup-github-repos.sh --apply
#
#   --apply     make the writes and read them back
#   -h, --help  print this help
set -euo pipefail

print_usage() {
    sed -n '/^# Usage:/,/^#   -h, --help/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

apply=false
while [ "$#" -gt 0 ]; do
    case "$1" in
    --apply) apply=true ;;
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

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091 # dynamic paths; both files live beside this script
source "$repo_root/scripts/deploy-targets.sh"
# shellcheck disable=SC1091
source "$repo_root/scripts/github-environment.sh"

command -v gh >/dev/null || { echo "gh CLI not found. Install: https://cli.github.com" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in to GitHub. Run 'gh auth login'." >&2; exit 1; }

if [ "$apply" != true ]; then
    export GH_DRY_RUN=true
    echo ">> Dry run: reads run, writes are printed and not made. Pass --apply to write."
fi

MAIN_BYPASS_USER=jm-rivera
RELEASE_TEAM=release
RETIRED_ENVIRONMENTS="sync sync-guard staging"
AUTO_MERGE_REPOS="infra"
ACTIONS_APP_ID=15368
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ruleset <name> <ref> <bypass> <pull_request> <checks> <strict> prints a
# branch ruleset. <bypass> is a JSON array of bypass actors, <pull_request>
# the pull_request rule's parameters or null for no such rule, and <checks>
# a JSON array of required check names, empty for no such rule. Every
# ruleset blocks deletion and force pushes.
ruleset() {
    jq -n --arg name "$1" --arg ref "$2" --argjson bypass "$3" --argjson pr "$4" \
        --argjson checks "$5" --argjson strict "$6" --argjson app "$ACTIONS_APP_ID" '{
        name: $name,
        target: "branch",
        enforcement: "active",
        bypass_actors: $bypass,
        conditions: {ref_name: {include: [$ref], exclude: []}},
        rules: ([{type: "deletion"}, {type: "non_fast_forward"}]
            + (if $pr == null then [] else [{type: "pull_request", parameters: ({
                require_code_owner_review: false,
                required_reviewers: []
            } + $pr)}] end)
            + (if $checks == [] then [] else [{type: "required_status_checks", parameters: {
                strict_required_status_checks_policy: $strict,
                do_not_enforce_on_create: false,
                required_status_checks: [$checks[] | {context: ., integration_id: $app}]
            }}] end))
    }'
}

# pr <approvals> <dismiss-stale> <last-push> <thread-resolution> <methods>
# prints pull_request rule parameters; <methods> is a JSON array.
pr() {
    jq -n --argjson n "$1" --argjson d "$2" --argjson l "$3" --argjson t "$4" --argjson m "$5" '{
        required_approving_review_count: $n,
        dismiss_stale_reviews_on_push: $d,
        require_last_push_approval: $l,
        required_review_thread_resolution: $t,
        allowed_merge_methods: $m
    }'
}

ALL_METHODS='["merge","squash","rebase"]'
ADMIN_BYPASS='[{"actor_type":"RepositoryRole","actor_id":5,"bypass_mode":"always"}]'

# main_ruleset <name> prints the repo's `main` ruleset.
main_ruleset() {
    local checks='[]'
    [ "$1" = infra ] && checks='["terraform fmt check","Prod changed stacks planned"]'
    ruleset main refs/heads/main \
        "$(jq -n --argjson id "$bypass_user_id" '[{actor_type: "User", actor_id: $id, bypass_mode: "pull_request"}]')" \
        "$(pr 1 true true false '["merge"]')" "$checks" false
}

# dev_ruleset <name> prints the repo's `dev` ruleset, or nothing for a repo
# with no `dev` branch. apis, ai, website and pipelines require pull requests
# and their CI checks, with an admin bypass. dcp
# needs a pull request with no approval and `checks / prototypes`, the one
# job of checks.yml that ci.yml runs on pull requests into dev. dcp allows
# merge commits only: its upstream syncs keep history shared with
# datacommonsorg/website through the merge's second parent, which a squash
# or rebase drops. ontology, docs, spec-kit and skills get only the
# deletion and force-push blocks every ruleset carries.
dev_ruleset() {
    case "$1" in
    infra)
        ruleset dev refs/heads/dev '[]' "$(pr 0 false false false "$ALL_METHODS")" \
            '["Changed stacks planned","terraform fmt check","Prod pin placeholder unchanged"]' false
        ;;
    apis)
        ruleset dev refs/heads/dev "$ADMIN_BYPASS" "$(pr 0 false false true "$ALL_METHODS")" \
            '["lint","test","docker"]' false
        ;;
    ai)
        ruleset dev refs/heads/dev "$ADMIN_BYPASS" "$(pr 0 true false true "$ALL_METHODS")" \
            '["lint","test","docker"]' false
        ;;
    website)
        ruleset dev refs/heads/dev "$ADMIN_BYPASS" "$(pr 0 false false false "$ALL_METHODS")" '["ci"]' false
        ;;
    pipelines)
        ruleset dev refs/heads/dev "$ADMIN_BYPASS" "$(pr 1 false false false '["squash","rebase"]')" \
            '["lint","test"]' true
        ;;
    dcp)
        ruleset dev refs/heads/dev '[]' "$(pr 0 false false false '["merge"]')" '["checks / prototypes"]' false
        ;;
    ontology | docs | spec-kit | skills)
        ruleset dev refs/heads/dev '[]' null '[]' false
        ;;
    *) return 1 ;;
    esac
}

# The fields this script sets on a ruleset, as one comparable value, from a
# ruleset body or a ruleset GET. GitHub fills in defaults the body leaves
# out, so the two compare only through this.
NORM='{
    name, target, enforcement,
    bypass: ((.bypass_actors // []) | map({actor_type, actor_id, bypass_mode: (.bypass_mode // "always")}) | sort_by(.actor_type, .actor_id)),
    include: ((.conditions.ref_name.include // []) | sort),
    exclude: ((.conditions.ref_name.exclude // []) | sort),
    rules: (.rules | map(
        if .type == "pull_request" then {type, p: (.parameters | {
            required_approving_review_count, dismiss_stale_reviews_on_push,
            require_last_push_approval, require_code_owner_review,
            required_review_thread_resolution,
            allowed_merge_methods: (.allowed_merge_methods // [] | sort)})}
        elif .type == "required_status_checks" then {type, p: {
            strict: .parameters.strict_required_status_checks_policy,
            checks: (.parameters.required_status_checks | map({context, integration_id: (.integration_id // null)}) | sort_by(.context))}}
        else {type} end) | sort_by(.type))
}'

# ruleset_id <slug> <name> prints the id of the repo's own ruleset of that
# name, or nothing.
ruleset_id() {
    gh api "repos/$1/rulesets?includes_parents=false" \
        --jq ".[] | select(.name == \"$2\" and .source_type == \"Repository\") | .id"
}

# converge_ruleset <slug> <body-file>: creates or replaces the repo's
# ruleset of the body's name, unless it already matches.
converge_ruleset() {
    local slug="$1" file="$2" name id want have
    name="$(jq -r .name "$file")"
    want="$(jq -c "$NORM" "$file")"
    id="$(ruleset_id "$slug" "$name")" || return 1
    if [ -n "$id" ]; then
        have="$(gh api "repos/$slug/rulesets/$id" | jq -c "$NORM")" || return 1
        if [ "$have" = "$want" ]; then
            echo ">> '$name' ruleset on $slug already matches."
            return 0
        fi
        echo ">> Replacing the '$name' ruleset ($id) on $slug."
        echo "   was:  $have"
        echo "   want: $want"
        gh_write api --method PUT "repos/$slug/rulesets/$id" --input "$file" --silent
    else
        echo ">> Creating the '$name' ruleset on $slug."
        echo "   want: $want"
        gh_write api --method POST "repos/$slug/rulesets" --input "$file" --silent
    fi
}

# check_ruleset <slug> <body-file>: PASS or FAIL on the ruleset as GitHub
# holds it.
check_ruleset() {
    local slug="$1" file="$2" name id
    name="$(jq -r .name "$file")"
    id="$(ruleset_id "$slug" "$name")" || return 1
    if [ -z "$id" ]; then
        echo "FAIL  $slug: no '$name' ruleset."
        return 1
    fi
    if [ "$(gh api "repos/$slug/rulesets/$id" | jq -c "$NORM")" = "$(jq -c "$NORM" "$file")" ]; then
        echo "PASS  $slug: '$name' ruleset matches."
        return 0
    fi
    echo "FAIL  $slug: '$name' ruleset differs from what this script sets."
    return 1
}

# ── Preflight ───────────────────────────────────

bypass_user_id="$(gh api "users/$MAIN_BYPASS_USER" --jq .id)"
release_team_id="$(gh api "orgs/$GITHUB_OWNER/teams/$RELEASE_TEAM" --jq .id)"

echo ">> Preflight..."
repos="" problems=0
for name in $(org_repos); do
    slug="$(org_repo "$name")"
    if ! gh api "repos/$slug" --silent 2>/dev/null; then
        echo "PRECONDITION  $slug does not exist; create it first."
        problems=$((problems + 1))
        continue
    fi
    if [ "$(default_branch "$name")" = dev ] && ! gh api "repos/$slug/branches/dev" --silent 2>/dev/null; then
        echo "PRECONDITION  $slug has no 'dev' branch; seed it before its default branch moves."
        problems=$((problems + 1))
    fi
    repos="$repos $name"
done
covered="$(echo "$repos" | wc -w | tr -d ' ')"
echo ">> $covered repos to converge, $problems precondition(s) unmet."
if [ "$problems" -gt 0 ] && [ "$apply" = true ]; then
    echo "ERROR: --apply writes nothing until every precondition above is met." >&2
    exit 1
fi
if [ "$covered" -eq 0 ]; then
    echo "ERROR: no repo to converge." >&2
    exit 1
fi

# ── 1. Release team write ─────────────────────

for name in $repos; do
    slug="$(org_repo "$name")"
    push="$(gh api "orgs/$GITHUB_OWNER/teams/$RELEASE_TEAM/repos/$slug" \
        -H 'Accept: application/vnd.github.v3.repository+json' --jq .permissions.push 2>/dev/null || echo false)"
    if [ "$push" = true ]; then
        echo ">> $RELEASE_TEAM already has write on $slug."
    else
        echo ">> Giving $RELEASE_TEAM write on $slug."
        gh_write api --method PUT "orgs/$GITHUB_OWNER/teams/$RELEASE_TEAM/repos/$slug" -f permission=push --silent
    fi
done

# ── 2 and 3. Rulesets, main first ─────────────

for name in $repos; do
    main_ruleset "$name" >"$work/$name.main.json"
    converge_ruleset "$(org_repo "$name")" "$work/$name.main.json"
done
for name in $repos; do
    dev_ruleset "$name" >"$work/$name.dev.json"
    [ -s "$work/$name.dev.json" ] || continue
    converge_ruleset "$(org_repo "$name")" "$work/$name.dev.json"
done

# ── 4. Environments ───────────────────────────

for name in $repos; do
    while read -r env branch reviewers; do
        [ -z "$env" ] && continue
        case "$reviewers" in
        -) team=- ;;
        "$RELEASE_TEAM") team="$release_team_id" ;;
        *)
            echo "ERROR: REPO_ENVIRONMENTS names reviewers '$reviewers'; this script resolves only $RELEASE_TEAM." >&2
            exit 1
            ;;
        esac
        converge_environment "$(org_repo "$name")" "$env" "$branch" "$team" || exit 1
    done <<<"$(repo_environments "$name")"
done

# ── 5. Retired environments ───────────────────

for name in $repos; do
    slug="$(org_repo "$name")"
    present="$(gh api --paginate "repos/$slug/environments" --jq '.environments[].name')"
    for env in $RETIRED_ENVIRONMENTS; do
        if printf '%s\n' "$present" | grep -qx "$env"; then
            echo ">> Deleting the retired '$env' environment on $slug."
            gh_write api --method DELETE "repos/$slug/environments/$env" --silent
        fi
    done
done

# ── 6. Default branches and auto-merge ────────

# auto_merge <name> prints true if the repo must allow auto-merge, else
# nothing.
auto_merge() {
    case " $AUTO_MERGE_REPOS " in
    *" $1 "*) printf 'true' ;;
    esac
}

for name in $repos; do
    slug="$(org_repo "$name")"
    want="$(default_branch "$name")"
    have="$(gh api "repos/$slug" --jq .default_branch)"
    if [ "$have" = "$want" ]; then
        echo ">> $slug already defaults to '$want'."
    else
        echo ">> Moving $slug's default branch from '$have' to '$want'."
        gh_write api --method PATCH "repos/$slug" -f default_branch="$want" --silent
    fi
    [ -n "$(auto_merge "$name")" ] || continue
    if [ "$(gh api "repos/$slug" --jq .allow_auto_merge)" = true ]; then
        echo ">> $slug already allows auto-merge."
    else
        echo ">> Allowing auto-merge on $slug."
        gh_write api --method PATCH "repos/$slug" -F allow_auto_merge=true --silent
    fi
done

# ── 7. infra's repo-level WIF values ──────────

infra_slug="$(org_repo infra)"
infra_wif_pending=""
case " $repos " in
*" infra "*)
    repo_wif="$(gh api --paginate "repos/$infra_slug/actions/variables" --jq '.variables[].name' | grep -E '^WIF_' || true)"
    if [ -z "$repo_wif" ]; then
        echo ">> $infra_slug holds no repo-level WIF value."
    else
        # The planner environments need the infra-plan values, the
        # appliers the infra-apply values.
        for dfo_env in dfo-dev dfo-prod; do
            while read -r _ env _ values_key; do
                [ -z "$env" ] && continue
                held="$(gh api --paginate "repos/$infra_slug/environments/$env/variables" --jq '.variables[].name' 2>/dev/null || true)"
                while read -r _ var _ _; do
                    [ -z "$var" ] && continue
                    printf '%s\n' "$held" | grep -qx "$var" || infra_wif_pending="$infra_wif_pending $env:$var"
                done <<<"$(deploy_values "$values_key")"
            done <<<"$(handoff_targets "$dfo_env" infra)"
        done
        if [ -n "$infra_wif_pending" ]; then
            echo ">> Keeping $infra_slug's repo-level $(echo "$repo_wif" | tr '\n' ' ')until every infra environment holds its own; missing:$infra_wif_pending."
            echo "   Run scripts/handoff.sh dfo-dev infra and scripts/handoff.sh dfo-prod infra, then this script again."
        else
            for var in $repo_wif; do
                echo ">> Deleting $infra_slug's repo-level $var; every infra environment holds its own."
                gh_write api --method DELETE "repos/$infra_slug/actions/variables/$var" --silent
            done
        fi
    fi
    ;;
esac

# ── Read back ─────────────────────────────────

if [ "$apply" != true ]; then
    echo ""
    echo "Dry run done over $covered repos. Run with --apply to make the writes above."
    exit 0
fi

echo ""
echo ">> Reading back..."
failed=0
for name in $repos; do
    slug="$(org_repo "$name")"
    if [ "$(gh api "orgs/$GITHUB_OWNER/teams/$RELEASE_TEAM/repos/$slug" \
        -H 'Accept: application/vnd.github.v3.repository+json' --jq .permissions.push 2>/dev/null)" = true ]; then
        echo "PASS  $slug: $RELEASE_TEAM has write."
    else
        echo "FAIL  $slug: $RELEASE_TEAM lacks write."
        failed=$((failed + 1))
    fi
    check_ruleset "$slug" "$work/$name.main.json" || failed=$((failed + 1))
    if [ -s "$work/$name.dev.json" ]; then
        check_ruleset "$slug" "$work/$name.dev.json" || failed=$((failed + 1))
    fi
    while read -r env branch _; do
        [ -z "$env" ] && continue
        check_environment "$slug" "$env" "$branch" || failed=$((failed + 1))
    done <<<"$(repo_environments "$name")"
    present="$(gh api --paginate "repos/$slug/environments" --jq '.environments[].name')"
    for env in $RETIRED_ENVIRONMENTS; do
        if printf '%s\n' "$present" | grep -qx "$env"; then
            echo "FAIL  $slug: retired '$env' environment still exists."
            failed=$((failed + 1))
        fi
    done
    have="$(gh api "repos/$slug" --jq .default_branch)"
    if [ "$have" = "$(default_branch "$name")" ]; then
        echo "PASS  $slug: defaults to '$have'."
    else
        echo "FAIL  $slug: defaults to '$have', expected '$(default_branch "$name")'."
        failed=$((failed + 1))
    fi
    if [ -n "$(auto_merge "$name")" ]; then
        if [ "$(gh api "repos/$slug" --jq .allow_auto_merge)" = true ]; then
            echo "PASS  $slug: allows auto-merge."
        else
            echo "FAIL  $slug: does not allow auto-merge."
            failed=$((failed + 1))
        fi
    fi
done
if [ -z "$infra_wif_pending" ] && case " $repos " in *" infra "*) true ;; *) false ;; esac; then
    if gh api --paginate "repos/$infra_slug/actions/variables" --jq '.variables[].name' | grep -qE '^WIF_'; then
        echo "FAIL  $infra_slug: still holds repo-level WIF values."
        failed=$((failed + 1))
    else
        echo "PASS  $infra_slug: no repo-level WIF value."
    fi
fi

if [ "$failed" -gt 0 ]; then
    echo "ERROR: $failed setting(s) did not read back as set." >&2
    exit 1
fi
if [ -n "$infra_wif_pending" ]; then
    echo "Done over $covered repos. infra's repo-level WIF values remain until its environments hold their own."
else
    echo "Done over $covered repos; every setting read back as set."
fi
