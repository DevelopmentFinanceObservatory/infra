#!/usr/bin/env bash
# Decide whether a PR into a DevelopmentFinanceObservatory repo's main may
# merge, for the sync-guard action in .github/actions/sync-guard and the
# verify job in .github/workflows/plan-prod.yml.
#
# Every PR that passes is one commit whose only parent is the PR's base
# commit. With main's ruleset requiring branches to be up to date, the base
# is main's head at merge time, so the merged tree is the head tree.
#
# Two kinds of PR pass:
#   - A sync PR. Its head commit carries one trailer
#     "Synced-from: ONEcampaign/<source>@<sha>", where <source> is this
#     repo's source in sync-lib.sh, <sha> is on the source branch, and the
#     head commit's tree equals the tree sync-tree.sh builds for <sha>
#     against the PR's base commit. <sha> must also be the source branch's
#     release floor, the newest commit there that touched a release-control
#     path in sync-lib.sh, or a descendant of it, so a sync cannot put back
#     an older guard.
#   - An image-pin PR. It is opened by dfo-release[bot], its commit is
#     authored and committed by dfo-release[bot] with a verified signature,
#     and it changes only the pin line in this repo's excluded paths, each
#     still a regular file. The line keeps base's registry path and changes
#     only the digest, except on the first pin, when base holds null.
# Everything else fails, with the reason on stderr and in the step summary.
#
# The script reads git objects and the GitHub API only. It never checks out
# or runs anything from the PR.
#
# Usage: sync-guard.sh <target> <base-sha> <head-sha> <pr-author>
# Env:   SYNC_TARGET_TOKEN  reads the target repo
#        SYNC_SOURCE_TOKEN  reads the source repo in ONEcampaign
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/sync-lib.sh
. "$SCRIPT_DIR/sync-lib.sh"

if [ "$#" -ne 4 ]; then
    echo "usage: $(basename "$0") <target> <base-sha> <head-sha> <pr-author>" >&2
    exit 2
fi
target="$1" base="$2" head="$3" author="$4"

report() {
    echo "$1" >&2
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
    fi
}
pass() {
    report "sync-guard passed: $1"
    exit 0
}
fail() {
    [ "${GITHUB_ACTIONS:-}" = "true" ] && echo "::error::$1"
    report "sync-guard failed for $head: $1"
    exit 1
}

sync_lookup_target "$target"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git init --quiet --bare "$work/repo"
cd "$work/repo"
sync_fetch "$(sync_target_url)" "${SYNC_TARGET_TOKEN:-}" "$base" "$head"

# The base must be the head's only parent. A head on an older main would
# merge three-way and land a tree no check saw, and a merge commit, such as
# the one "Update branch" makes, carries changes from its other parent.
parents="$(sync_parents "$head")"
parent_count="$(printf '%s' "$parents" | grep -c . || true)"
if [ "$parent_count" -ne 1 ]; then
    fail "the head commit has $parent_count parents, and a PR must be one commit on its base $base. If main has moved, dispatch sync.yml again, or re-run the pin, rather than updating the branch."
fi
if [ "$parents" != "$base" ]; then
    fail "the head commit's parent is $parents, not the PR's base $base. If main has moved, dispatch sync.yml again, or re-run the pin."
fi

head_tree="$(git rev-parse "$head^{tree}")"
synced_from="$(git log -1 --format=%B "$head" | git interpret-trailers --parse |
    sed -n 's/^Synced-from: //p')"

if [ -n "$synced_from" ]; then
    if [ "$(printf '%s\n' "$synced_from" | wc -l)" -ne 1 ]; then
        fail "the head commit carries more than one Synced-from trailer."
    fi
    if ! [[ "$synced_from" =~ ^$SYNC_SOURCE_OWNER/([A-Za-z0-9._-]+)@([0-9a-f]{40})$ ]]; then
        fail "the Synced-from trailer '$synced_from' is not $SYNC_SOURCE_OWNER/<repo>@<full sha>."
    fi
    source_repo="${BASH_REMATCH[1]}" source_sha="${BASH_REMATCH[2]}"
    if [ "$source_repo" != "$SYNC_SOURCE" ]; then
        fail "$SYNC_TARGET syncs from $SYNC_SOURCE_OWNER/$SYNC_SOURCE, but the trailer names $source_repo."
    fi
    if ! GH_TOKEN="${SYNC_SOURCE_TOKEN:-}" sync_reachable "$SYNC_SOURCE" "$SYNC_BRANCH" "$source_sha"; then
        fail "$source_sha is not on $SYNC_SOURCE_OWNER/$SYNC_SOURCE's $SYNC_BRANCH branch."
    fi
    sync_fetch_source "${SYNC_SOURCE_TOKEN:-}" "$source_sha"
    if ! floor_error="$(sync_check_floor "$source_sha" 2>&1)"; then
        fail "$floor_error"
    fi
    expected="$("$SCRIPT_DIR/sync-tree.sh" "$SYNC_TARGET" "$source_sha" "$base")"
    if [ "$expected" != "$head_tree" ]; then
        report "Paths that differ from the expected tree:"
        report "$(git diff-tree -r --no-renames --name-status "$expected" "$head_tree" | head -n 20)"
        fail "the head tree $head_tree differs from $expected, the tree sync-tree.sh builds for $SYNC_SOURCE@$source_sha on base $base. If main has moved, dispatch sync.yml again for $source_sha."
    fi
    pass "the head tree is $SYNC_SOURCE_OWNER/$SYNC_SOURCE@$source_sha on base $base."
fi

if [ -z "$SYNC_EXCLUDES" ]; then
    fail "the head commit has no Synced-from trailer, and $SYNC_TARGET accepts only sync PRs."
fi
if [ "$author" != "$SYNC_PIN_AUTHOR" ]; then
    fail "the head commit has no Synced-from trailer, and only $SYNC_PIN_AUTHOR may open the other PRs $SYNC_TARGET accepts, which change only: $SYNC_EXCLUDES. This PR's author is $author."
fi

# The base line holds a pinned digest, or null, the placeholder before the
# first pin. The head line is exactly what build-and-pin.yml writes. After
# the first pin, the head keeps base's registry path and changes only the
# digest, so a pin cannot point prod at another project or repository.
old_re="^${SYNC_PIN_KEY}[[:space:]]*=[[:space:]]*(null|\"([^\"]*)\")\$"
new_re="^${SYNC_PIN_KEY} = \"(.*)\"\$"
changed="$(git diff-tree -r --no-renames --name-only "$base" "$head")"
if [ -z "$changed" ]; then
    fail "the PR changes nothing against base $base."
fi
while IFS= read -r path; do
    case " $SYNC_EXCLUDES " in
    *" $path "*) ;;
    *) fail "an image-pin PR may change only $SYNC_EXCLUDES, and this one also changes $path." ;;
    esac
    entry="$(git ls-tree "$head" -- "$path")"
    if [ -z "$entry" ]; then
        fail "an image-pin PR may not remove $path."
    fi
    read -r mode type _ <<<"$entry"
    if [ "$type" != "blob" ] || [ "$mode" != "100644" ]; then
        fail "$path is a $type with mode $mode in the head, and a pin must stay a regular file (100644)."
    fi
    if [ -z "$(git ls-tree "$base" -- "$path")" ]; then
        fail "base $base has no $path, so there is no pin line to replace."
    fi
    git cat-file blob "$base:$path" >"$work/old"
    git cat-file blob "$head:$path" >"$work/new"
    # Prints the base line and the head line of the one line that differs,
    # or nothing when the files differ in line count or in more than one
    # line.
    lines="$(awk '
        FILENAME == ARGV[1] { old[FNR] = $0; n_old = FNR; next }
        { n_new = FNR; if ($0 != old[FNR]) { count++; was = old[FNR]; now = $0 } }
        END { if (n_old == n_new && count == 1) { print was; print now } }
    ' "$work/old" "$work/new")"
    if [ -z "$lines" ]; then
        fail "an image-pin PR may replace one line of $path, and this one changes more, or fewer."
    fi
    old_line="${lines%%$'\n'*}" new_line="${lines#*$'\n'}"
    if ! [[ "$old_line" =~ $old_re ]]; then
        fail "the line the PR replaces in $path is not the $SYNC_PIN_KEY assignment: $old_line"
    fi
    old_value="${BASH_REMATCH[2]}"
    if [ "${BASH_REMATCH[1]}" != null ] && ! [[ "$old_value" =~ $SYNC_PIN_VALUE_RE ]]; then
        fail "base's $SYNC_PIN_KEY in $path is neither null nor a pinned digest, so there is no registry path to keep: $old_line"
    fi
    new_value=""
    [[ "$new_line" =~ $new_re ]] && new_value="${BASH_REMATCH[1]}"
    if ! [[ "$new_value" =~ $SYNC_PIN_VALUE_RE ]]; then
        fail "the new line in $path is not $SYNC_PIN_KEY = \"<registry path>@sha256:<digest>\": $new_line"
    fi
    if [ -n "$old_value" ] && [ "${new_value%@sha256:*}" != "${old_value%@sha256:*}" ]; then
        fail "the new pin in $path moves the registry path from ${old_value%@sha256:*} to ${new_value%@sha256:*}, and a pin may change only the digest."
    fi
done <<<"$changed"

# The PR's commits, judged on the event's base and head so a later push
# cannot change the list. Fields are documented under "Compare two commits"
# in GitHub's REST commits API: each commit's author and committer logins,
# and commit.verification.verified. GitHub signs a commit a GitHub App
# makes through the API with no custom author or committer, so a commit
# pushed with the App's token from a local git does not verify.
commits="$(GH_TOKEN="${SYNC_TARGET_TOKEN:-}" gh api "repos/$SYNC_TARGET_OWNER/$SYNC_TARGET/compare/$base...$head" \
    --jq '.commits[] | [.sha, (.author.login // "none"), (.committer.login // "none"), (.commit.verification.verified | tostring)] | @tsv')" ||
    fail "the commits between $base and $head could not be listed."
if [ -z "$commits" ]; then
    fail "the API lists no commits between $base and $head."
fi
while IFS=$'\t' read -r sha commit_author committer verified; do
    if [ "$commit_author" != "$SYNC_PIN_AUTHOR" ] || [ "$committer" != "$SYNC_PIN_AUTHOR" ] || [ "$verified" != "true" ]; then
        fail "commit $sha has author $commit_author, committer $committer and verified $verified. Every commit in an image-pin PR must be authored and committed by $SYNC_PIN_AUTHOR with a verified signature."
    fi
done <<<"$commits"
pass "an image-pin PR from $SYNC_PIN_AUTHOR that changes only the pin line in $SYNC_EXCLUDES."
