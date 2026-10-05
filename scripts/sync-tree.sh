#!/usr/bin/env bash
# Build the tree a DevelopmentFinanceObservatory repo's main should hold for
# a ONEcampaign source commit, and print its id.
#
# The tree is the source commit's tree with each of the target's excluded
# paths put back as base main has it, or removed when base main has no entry
# there. An excluded path in base main must be a regular file. With no base commit, for the first snapshot into an empty repo, the
# source tree is used whole, which seeds the excluded paths from the source.
#
# Works on git objects only, through a private index, so file modes,
# symlinks and submodule gitlinks carry across unchanged and the caller's
# own index is untouched. sync.yml, sync-guard.sh and push-first-snapshot.sh
# all call this script, so the tree a release builds and the tree the guard
# expects come from one implementation.
#
# Usage: sync-tree.sh <target> <source-commit> [<base-commit>]
#   Run inside a git repo (bare or not) that holds both commits' objects.
#   <target> is the new repo's name, for example "infra".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/sync-lib.sh
. "$SCRIPT_DIR/sync-lib.sh"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "usage: $(basename "$0") <target> <source-commit> [<base-commit>]" >&2
    exit 2
fi

sync_lookup_target "$1"
source_tree="$(git rev-parse --verify --quiet "$2^{tree}")" || {
    echo "Source commit $2 is not in this repo." >&2
    exit 1
}
base=""
if [ -n "${3:-}" ]; then
    base="$(git rev-parse --verify --quiet "$3^{commit}")" || {
        echo "Base commit $3 is not in this repo." >&2
        exit 1
    }
fi

index_dir="$(mktemp -d)"
trap 'rm -rf "$index_dir"' EXIT
export GIT_INDEX_FILE="$index_dir/index"

git read-tree "$source_tree"

if [ -n "$base" ]; then
    for path in $SYNC_EXCLUDES; do
        # ls-tree prints "<mode> <type> <id><TAB><path>" for the one entry.
        entry="$(git ls-tree "$base" -- "$path")"
        if [ -z "$entry" ]; then
            git update-index --force-remove -- "$path"
            continue
        fi
        read -r mode type id _ <<<"$entry"
        # Only a regular file. A symlink here could point prod's Terraform
        # at another environment's values, and every later sync would carry
        # it forward.
        if [ "$type" != "blob" ] || [ "$mode" != "100644" ]; then
            echo "Excluded path $path is a $type with mode $mode in base $base, expected a regular file (100644)." >&2
            exit 1
        fi
        git update-index --add --cacheinfo "$mode,$id,$path"
    done
fi

git write-tree
