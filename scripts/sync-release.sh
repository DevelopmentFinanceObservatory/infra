#!/usr/bin/env bash
# Open the sync PR that releases a ONEcampaign commit into its
# DevelopmentFinanceObservatory repo, for .github/workflows/sync.yml.
#
# Builds the tree with sync-tree.sh against the target's main, commits it
# onto main with the Synced-from trailer, and force-pushes release/<target>,
# the target's one sync branch. An open PR from that branch is retitled for the
# new commit; otherwise the script opens one. Each target therefore has at
# most one sync PR, which follows the newest release. A re-run for the same
# commit keeps the branch when it already holds that commit's tree, trailer
# and current main as parent. When main already holds the tree there is
# nothing to release and the script stops. Open PRs from the older
# per-commit branches, sync/<target>/<sha>, are closed with a comment
# naming the current one. The branch lives outside sync/, since git cannot
# hold sync/<target> beside the sync/<target>/<sha> branches left from
# merged PRs. A commit older than the source branch's
# release floor, the newest commit that touched a release-control path in
# sync-lib.sh, is refused before anything is pushed.
#
# Usage: sync-release.sh <target> [<sha>]
#   <sha> defaults to the head of the target's source branch.
# Env:   SYNC_SOURCE_TOKEN  reads the source repo in ONEcampaign
#        SYNC_TARGET_TOKEN  writes contents, pull requests and workflows on
#                           the target repo
#        GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_COMMITTER_NAME,
#        GIT_COMMITTER_EMAIL  the identity of the sync commit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/sync-lib.sh
. "$SCRIPT_DIR/sync-lib.sh"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: $(basename "$0") <target> [<sha>]" >&2
    exit 2
fi
sync_lookup_target "$1"
source_slug="$SYNC_SOURCE_OWNER/$SYNC_SOURCE"
target_slug="$SYNC_TARGET_OWNER/$SYNC_TARGET"

# The commits API resolves a branch name or an abbreviated id to a full id,
# and fails for anything the source repo does not hold.
sha="$(GH_TOKEN="$SYNC_SOURCE_TOKEN" gh api "repos/$source_slug/commits/${2:-$SYNC_BRANCH}" --jq .sha)"
if ! GH_TOKEN="$SYNC_SOURCE_TOKEN" sync_reachable "$SYNC_SOURCE" "$SYNC_BRANCH" "$sha"; then
    echo "$sha is not on $source_slug's $SYNC_BRANCH branch." >&2
    exit 1
fi
branch="release/$SYNC_TARGET"
echo "Releasing $source_slug@$sha into $target_slug on $branch." >&2

target_url="$(sync_target_url)"
auth=()
while IFS= read -r arg; do auth+=("$arg"); done < <(sync_git_auth "$SYNC_TARGET_TOKEN")

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git init --quiet --bare "$work"
cd "$work"

remote_refs="$(git ${auth[@]+"${auth[@]}"} ls-remote "$target_url" refs/heads/main "refs/heads/$branch")"
main="$(awk '$2 == "refs/heads/main" { print $1 }' <<<"$remote_refs")"
existing="$(awk -v ref="refs/heads/$branch" '$2 == ref { print $1 }' <<<"$remote_refs")"
if [ -z "$main" ]; then
    echo "$target_slug has no main. Push its first snapshot with scripts/push-first-snapshot.sh." >&2
    exit 1
fi

sync_fetch "$target_url" "$SYNC_TARGET_TOKEN" "$main" ${existing:+"$existing"}
sync_fetch_source "$SYNC_SOURCE_TOKEN" "$sha"
sync_check_floor "$sha" || exit 1
tree="$("$SCRIPT_DIR/sync-tree.sh" "$SYNC_TARGET" "$sha" "$main")"

if [ "$tree" = "$(git rev-parse "$main^{tree}")" ]; then
    echo "$target_slug main already holds the tree for $source_slug@$sha. Nothing to release." >&2
    exit 0
fi

# The guard admits only one commit with this tree whose single parent is
# the PR's base, and main's ruleset requires the branch to be up to date, so
# the branch is reusable only when it holds this tree on the current main.
# The trailer must name this commit too, since two source commits can build
# the same tree.
trailer="$(sync_trailer "$SYNC_SOURCE" "$sha")"
if [ -n "$existing" ] &&
    [ "$(git rev-parse "$existing^{tree}")" = "$tree" ] &&
    [ "$(sync_parents "$existing")" = "$main" ] &&
    git log -1 --format=%B "$existing" | grep -qxF "$trailer"; then
    commit="$existing"
    echo "$branch already holds $commit on the current main." >&2
else
    commit="$(git commit-tree "$tree" -p "$main" \
        -m "Sync $source_slug@$sha" \
        -m "$trailer")"
    git ${auth[@]+"${auth[@]}"} push --quiet --force "$target_url" "$commit:refs/heads/$branch"
    echo "Pushed $commit to $branch." >&2
fi

export GH_TOKEN="$SYNC_TARGET_TOKEN"
title="Sync $SYNC_SOURCE@${sha:0:12}"
body="Releases [$source_slug@$sha](https://github.com/$source_slug/commit/$sha), from its \`$SYNC_BRANCH\` branch, into \`main\`. Merging this PR is the release. A newer release updates this PR in place."
pr="$(gh pr list --repo "$target_slug" --head "$branch" --state open --json number --jq '.[0].number // empty')"
if [ -n "$pr" ]; then
    gh pr edit "$pr" --repo "$target_slug" --title "$title" --body "$body" >/dev/null
else
    gh pr create --repo "$target_slug" --base main --head "$branch" --title "$title" --body "$body" >/dev/null
    pr="$(gh pr list --repo "$target_slug" --head "$branch" --state open --json number --jq '.[0].number')"
fi
echo "Sync PR: https://github.com/$target_slug/pull/$pr" >&2

others="$(gh pr list --repo "$target_slug" --state open --limit 200 --json number,headRefName \
    --jq ".[] | select(.headRefName | startswith(\"sync/$SYNC_TARGET/\")) | select(.number != $pr) | .number")"
closed=0
for other in $others; do
    gh pr close "$other" --repo "$target_slug" --delete-branch \
        --comment "Superseded by #$pr, the repo's one sync PR, which releases $source_slug@$sha and updates in place from now on."
    closed=$((closed + 1))
done
echo "Closed $closed per-commit sync PR(s)." >&2
