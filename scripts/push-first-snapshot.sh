#!/usr/bin/env bash
# Build the first commit for an empty DevelopmentFinanceObservatory repo from
# a ONEcampaign commit, and print the git push that publishes it as main.
#
# An admin runs this by hand once per repo. sync.yml cannot, since the empty
# repo has no main to open a PR against and infra's own sync.yml does not
# exist yet. The commit has no parent, carries the same Synced-from trailer
# as every sync, and takes its author and committer from the operator's git
# config. The script never pushes.
#
# Refuses when the target repo has any ref, when the commit is not on the
# source branch, when it is older than the branch's release floor (see
# sync_check_floor in sync-lib.sh), or when git has no user.name and
# user.email.
#
# Usage: push-first-snapshot.sh <source-repo> <sha>
#   <source-repo> is the ONEcampaign name, for example dfo-apis.
#   <sha> is the full 40-character commit id.
#   Needs git credentials that can read ONEcampaign/<source-repo> and list
#   DevelopmentFinanceObservatory/<target>.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/sync-lib.sh
. "$SCRIPT_DIR/sync-lib.sh"

if [ "$#" -ne 2 ]; then
    echo "usage: $(basename "$0") <source-repo> <sha>" >&2
    exit 2
fi
sync_lookup_source "$1"
sha="$2"
if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Expected a full 40-character commit id, got: $sha" >&2
    exit 2
fi

target_url="$(sync_target_url)"

target_refs="$(git ls-remote "$target_url")"
if [ -n "$target_refs" ]; then
    echo "$SYNC_TARGET_OWNER/$SYNC_TARGET is not empty, so it needs a sync PR, not a first snapshot:" >&2
    printf '%s\n' "$target_refs" | sed 's/^/  /' >&2
    exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/snapshot-$SYNC_TARGET.XXXXXX")"
git init --quiet --bare "$work"
cd "$work"

# The whole source branch, so the ancestry and floor checks below run
# locally.
sync_fetch_source ""
if ! git cat-file -e "$sha^{commit}" 2>/dev/null ||
    ! git merge-base --is-ancestor "$sha" "$SYNC_SOURCE_REF"; then
    echo "$sha is not on $SYNC_SOURCE_OWNER/$SYNC_SOURCE's $SYNC_BRANCH branch." >&2
    exit 1
fi
sync_check_floor "$sha" || exit 1

tree="$("$SCRIPT_DIR/sync-tree.sh" "$SYNC_TARGET" "$sha")"
commit="$(git commit-tree "$tree" \
    -m "Snapshot of $SYNC_SOURCE_OWNER/$SYNC_SOURCE@$sha" \
    -m "$(sync_trailer "$SYNC_SOURCE" "$sha")")"

echo "Built $commit (tree $tree) in $work." >&2
echo "Check it with: git -C $work show --stat $commit" >&2
echo "Publish it with:" >&2
printf 'git -C %q push %q %s:refs/heads/main\n' "$work" "$target_url" "$commit"
