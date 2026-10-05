#!/usr/bin/env bash
# Scenario tests for sync-pending.sh against a stub `gh`, so nothing reaches
# GitHub. The stub answers from files under $STUB: head/<source> holds a
# source branch's head, main/<target> and released/<target> hold a target's
# main and the commit its newest Synced-from trailer names, pr/<target>
# holds an open sync PR's commit, and parent/<commit> that commit's parent.
# A missing head file fails the call, as an unreadable repo would. A source
# read with anything but the source token, or a target read with anything
# but the target token, fails too.
# Run by hand after touching sync-pending.sh or the table in sync-lib.sh:
#   scripts/sync-pending.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
export STUB="$WORK/stub"

cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
"api repos/ONEcampaign/"*)
    [ "$GH_TOKEN" = source-token ] || exit 3
    src="${2#repos/ONEcampaign/}"
    src="${src%%/*}"
    [ -f "$STUB/head/$src" ] || exit 1
    printf '{"sha":"%s"}\n' "$(cat "$STUB/head/$src")"
    ;;
"api repos/DevelopmentFinanceObservatory/"*"/commits?sha=main"*)
    [ "$GH_TOKEN" = target-token ] || exit 3
    t="${2#repos/DevelopmentFinanceObservatory/}"
    t="${t%%/*}"
    jq -n --arg main "$(cat "$STUB/main/$t")" --arg released "$(cat "$STUB/released/$t")" --arg src "$(cat "$STUB/source/$t")" \
        '[{sha: $main, commit: {message: "Merge pull request #9 from DevelopmentFinanceObservatory/sync"}},
          {sha: "c", commit: {message: ("Snapshot\n\nSynced-from: ONEcampaign/other@" + ("f" * 40))}},
          {sha: "b", commit: {message: ("Snapshot of ONEcampaign/" + $src + "@" + $released + "\n\nSynced-from: ONEcampaign/" + $src + "@" + $released)}}]'
    ;;
"api repos/DevelopmentFinanceObservatory/"*"/commits/"*)
    [ "$GH_TOKEN" = target-token ] || exit 3
    oid="${2##*/}"
    printf '{"parents":[{"sha":"%s"}]}\n' "$(cat "$STUB/parent/$oid")"
    ;;
"pr list")
    [ "$GH_TOKEN" = target-token ] || exit 3
    t="${4#DevelopmentFinanceObservatory/}"
    if [ -f "$STUB/pr/$t" ]; then printf '[{"headRefOid":"%s"}]\n' "$(cat "$STUB/pr/$t")"; else echo '[]'; fi
    ;;
*)
    echo "stub: unexpected gh $*" >&2
    exit 2
    ;;
esac
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" SYNC_SOURCE_TOKEN=source-token SYNC_TARGET_TOKEN=target-token
[ "$(command -v gh)" = "$WORK/bin/gh" ] || { echo "gh stub not first on PATH" >&2; exit 1; }

# sha <n> prints a 40-character commit id built from the digit n.
sha() { printf "%040d" "$1"; }

# reset makes every target current: each head is the released commit.
reset() {
    rm -rf "$STUB"
    mkdir -p "$STUB/head" "$STUB/main" "$STUB/released" "$STUB/source" "$STUB/pr" "$STUB/parent"
    local n=0 target src
    # shellcheck source=scripts/sync-lib.sh
    while read -r target src _; do
        n=$((n + 1))
        sha "$n" >"$STUB/head/$src"
        sha "$n" >"$STUB/released/$target"
        sha "$((n + 50))" >"$STUB/main/$target"
        echo "$src" >"$STUB/source/$target"
    done < <(. "$SCRIPT_DIR/sync-lib.sh" && echo "$SYNC_TABLE")
    [ "$n" -eq 10 ] || { echo "expected 10 table rows, read $n" >&2; exit 1; }
}

failures=0
run() {
    set +e
    out="$("$SCRIPT_DIR/sync-pending.sh" 2>"$WORK/err")"
    status=$?
    set -e
    err="$(cat "$WORK/err")"
}
check() {
    if [ "$2" = true ]; then
        echo "ok: $1"
    else
        echo "FAIL: $1"
        printf '%s\n' "$out" | sed 's/^/    out: /'
        printf '%s\n' "$err" | sed 's/^/    err: /'
        failures=$((failures + 1))
    fi
}
is() { [ "$1" = "$2" ] && echo true || echo false; }

# 1. Every main holds its source head: nothing is pending.
reset
run
check "current exits 0" "$(is "$status" 0)"
check "current lists nothing" "$(is "$out" "")"
check "current checks all 10" "$([[ "$err" == *"Checked 10 repos, 0 pending."* ]] && echo true || echo false)"

# 2. A new source head with no PR is pending. A trailer naming another
# source repo does not count as a release.
reset
sha 91 >"$STUB/head/dfo-apis"
run
check "new head exits 0" "$(is "$status" 0)"
check "new head lists apis alone" "$(is "$out" apis)"

# 3. An open PR for the head on the current main is left alone.
reset
sha 92 >"$STUB/head/dfo-ai"
sha 93 >"$STUB/pr/ai"
cp "$STUB/main/ai" "$STUB/parent/$(sha 93)"
run
check "current PR lists nothing" "$(is "$out" "")"

# 4. An open PR on an older main is pending, so the run rebuilds it.
reset
sha 94 >"$STUB/head/dfo-website"
sha 95 >"$STUB/pr/website"
sha 96 >"$STUB/parent/$(sha 95)"
run
check "stale PR lists website" "$(is "$out" website)"

# 5. Several pending repos are each listed once, in table order.
reset
sha 97 >"$STUB/head/dfo-skills"
sha 98 >"$STUB/head/dfo-dcp"
run
check "two pending lists dcp then skills" "$(is "$out" "$(printf 'dcp\nskills')")"

# 6. An unreadable source repo stops the run with a failure.
reset
rm "$STUB/head/dfo-docs"
run
check "unreadable source exits non-zero" "$([ "$status" -ne 0 ] && echo true || echo false)"
check "unreadable source never reports checking all 10" "$([[ "$err" != *"Checked 10"* ]] && echo true || echo false)"

if [ "$failures" -eq 0 ]; then
    echo "All scenarios passed."
else
    echo "$failures check(s) failed."
    exit 1
fi
