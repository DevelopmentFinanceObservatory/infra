#!/usr/bin/env bash
# Print, one per line, each DevelopmentFinanceObservatory repo that needs a
# sync run, for the scheduled run of .github/workflows/sync.yml.
#
# A repo needs one when the head of its ONEcampaign source branch is not the
# commit named by the newest Synced-from trailer on its main, and no open
# sync PR for that head sits on the current main. An open PR whose commit's
# parent is an older main cannot merge under the strict ruleset, and a sync
# run rebuilds it on the current main. A head whose tree main already holds
# stays listed, and its sync run stops with nothing to release.
#
# Any failed read stops the script, so a run never reports a repo as
# current that it could not check. Each gh call reads /dev/null, so none
# can consume the table the loop reads.
#
# Usage: sync-pending.sh
# Env:   SYNC_SOURCE_TOKEN  reads every source repo in ONEcampaign
#        SYNC_TARGET_TOKEN  reads commits and pull requests on every target
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/sync-lib.sh
. "$SCRIPT_DIR/sync-lib.sh"

checked=0 pending=0
while IFS= read -r row; do
    _sync_set_row "$row"
    source_slug="$SYNC_SOURCE_OWNER/$SYNC_SOURCE"
    target_slug="$SYNC_TARGET_OWNER/$SYNC_TARGET"

    head="$(GH_TOKEN="$SYNC_SOURCE_TOKEN" gh api "repos/$source_slug/commits/$SYNC_BRANCH" </dev/null | jq -er .sha)"
    commits="$(GH_TOKEN="$SYNC_TARGET_TOKEN" gh api "repos/$target_slug/commits?sha=main&per_page=50" </dev/null)"
    main="$(jq -er '.[0].sha' <<<"$commits")"
    released="$(jq -r --arg slug "$source_slug" \
        '[.[].commit.message | capture("Synced-from: (?<slug>[^@\\s]+)@(?<sha>[0-9a-f]{40})") | select(.slug == $slug) | .sha][0] // ""' \
        <<<"$commits")"
    checked=$((checked + 1))

    if [ "$released" = "$head" ]; then
        echo "$target_slug main holds $source_slug@$head." >&2
        continue
    fi
    pr_commit="$(GH_TOKEN="$SYNC_TARGET_TOKEN" gh pr list --repo "$target_slug" --head "sync/$SYNC_TARGET/$head" \
        --state open --json headRefOid </dev/null | jq -r '.[0].headRefOid // ""')"
    pr_parent=""
    if [ -n "$pr_commit" ]; then
        pr_parent="$(GH_TOKEN="$SYNC_TARGET_TOKEN" gh api "repos/$target_slug/commits/$pr_commit" </dev/null | jq -er '.parents[0].sha')"
    fi
    if [ "$pr_parent" = "$main" ]; then
        echo "$target_slug has an open sync PR for $source_slug@$head on the current main." >&2
        continue
    fi
    echo "$target_slug needs a sync run for $source_slug@$head." >&2
    echo "$SYNC_TARGET"
    pending=$((pending + 1))
done <<<"$SYNC_TABLE"

if [ "$checked" -eq 0 ]; then
    echo "The sync table names no repos." >&2
    exit 1
fi
echo "Checked $checked repos, $pending pending." >&2
