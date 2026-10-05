#!/usr/bin/env bash
# Run sync-guard.sh and publish its verdict as the sync-guard check run on
# the PR's head commit, for the sync-guard action in .github/actions/sync-guard.
#
# The check run is the required check on main. The ruleset accepts it only
# from the release App, and only a job in the sync-guard environment can
# mint that App's token, so a check of the same name from any other
# workflow cannot satisfy it.
#
# The check run opens as in_progress before the guard runs, so a crash
# leaves it short of success. It closes as success or failure with the
# guard's report as its summary, and the script exits with the guard's
# status, so the job fails when the guard fails.
#
# Usage: sync-guard-check.sh <target> <base-sha> <head-sha> <pr-author>
# Env:   SYNC_CHECKS_TOKEN  writes check runs on the target repo
#        SYNC_TARGET_TOKEN, SYNC_SOURCE_TOKEN  passed on to sync-guard.sh
#        GITHUB_SERVER_URL, GITHUB_RUN_ID  when set, link the check run to
#                                          the workflow run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/sync-lib.sh
. "$SCRIPT_DIR/sync-lib.sh"

if [ "$#" -ne 4 ]; then
    echo "usage: $(basename "$0") <target> <base-sha> <head-sha> <pr-author>" >&2
    exit 2
fi
sync_lookup_target "$1"
head="$3"
repo="$SYNC_TARGET_OWNER/$SYNC_TARGET"
details_url=""
if [ -n "${GITHUB_RUN_ID:-}" ]; then
    details_url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/$GITHUB_RUN_ID"
fi

# checks_api <method> <path> [<gh api arg>...] sends the JSON body on stdin.
checks_api() {
    local method="$1" path="$2"
    shift 2
    GH_TOKEN="$SYNC_CHECKS_TOKEN" gh api --method "$method" "$path" --input - "$@"
}

check_id="$(jq -n --arg head "$head" --arg url "$details_url" \
    '{name: "sync-guard", head_sha: $head, status: "in_progress"}
     + (if $url == "" then {} else {details_url: $url} end)' |
    checks_api POST "repos/$repo/check-runs" --jq .id)"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
status=0
"$SCRIPT_DIR/sync-guard.sh" "$@" 2>"$log" || status=$?
cat "$log" >&2

if [ "$status" -eq 0 ]; then
    conclusion="success" title="sync-guard passed"
else
    conclusion="failure" title="sync-guard failed"
fi
# The API caps a summary at 65535 characters.
summary="$(head -c 60000 "$log")"
jq -n --arg conclusion "$conclusion" --arg title "$title" --arg summary "$summary" \
    '{status: "completed", conclusion: $conclusion,
      output: {title: $title, summary: ("```text\n" + $summary + "\n```")}}' |
    checks_api PATCH "repos/$repo/check-runs/$check_id" >/dev/null

exit "$status"
