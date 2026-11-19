#!/usr/bin/env bash
# Scenario tests for check-edge-cache.sh against a stub `curl`, so nothing
# reaches the edge. The stub answers its Nth call with the header block in
# file N of a queue directory and logs its arguments. Nothing runs it automatically; run it by hand after
# touching the script:
#   scripts/check-edge-cache.test.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-edge-cache.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
export STUB_LOG="$WORK/calls.log" STUB_QUEUE="$WORK/queue" STUB_COUNT="$WORK/count"

# curl: prints $STUB_QUEUE/N with CRLF line ends on its Nth call, and exits
# 22, as --fail-with-body does on an error status, when that file says FAIL.
cat >"$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$STUB_LOG"
n=$(($(cat "$STUB_COUNT") + 1))
echo "$n" >"$STUB_COUNT"
[ "$(cat "$STUB_QUEUE/$n")" = "FAIL" ] && exit 22
sed 's/$/\r/' "$STUB_QUEUE/$n"
STUB
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
[ "$(command -v curl)" = "$WORK/bin/curl" ] || { echo "curl stub not first on PATH" >&2; exit 1; }

FILE=/api/datasets/spec_a/cv_0123/files/sha256:ff
SELECTOR="/api/datasets/spec_a/cv_0123/file?format=csv"
failures=0

# run <queue statuses...>: queues one response per status ("FAIL" for a curl
# failure, "TAG:<status>" for a response carrying Cache-Tag), then runs the
# script on FILE and SELECTOR.
run() {
    : >"$STUB_LOG"
    rm -rf "$STUB_QUEUE"
    mkdir "$STUB_QUEUE"
    echo 0 >"$STUB_COUNT"
    local s n=0
    for s in "$@"; do
        n=$((n + 1))
        case "$s" in
        FAIL) echo FAIL >"$STUB_QUEUE/$n" ;;
        TAG:*) printf 'HTTP/2 200\ncache-tag: cv_0123\ncf-cache-status: %s\n\n' "${s#TAG:}" >"$STUB_QUEUE/$n" ;;
        *) printf 'HTTP/2 200\nCF-Cache-Status: %s\n\n' "$s" >"$STUB_QUEUE/$n" ;;
        esac
    done
    set +e
    out="$("$SCRIPT" "$FILE" "$SELECTOR" 2>&1)"
    status=$?
    set -e
    calls="$(cat "$STUB_LOG")"
}

check() {
    local label="$1" ok="$2"
    if [ "$ok" = true ]; then
        echo "ok: $label"
    else
        echo "FAIL: $label"
        printf '%s\n' "$out" | sed 's/^/    out: /'
        printf '%s\n' "$calls" | sed 's/^/    log: /'
        failures=$((failures + 1))
    fi
}

is() { [ "$1" = "$2" ] && echo true || echo false; }
says() { [[ "$out" == *"$1"* ]] && echo true || echo false; }

# 1. The edge answers as the ruleset intends: every check passes. The
# manifest path is the file path without /files/<digest>, the v1 manifest is
# the same path under /api/v1/datasets, only the seventh request sends Origin
# and only the eighth sends Authorization.
run MISS HIT MISS HIT MISS HIT BYPASS DYNAMIC DYNAMIC
check "expected statuses exit 0" "$(is "$status" 0)"
check "nine checks counted" "$(says "9 checks, 0 failed.")"
check "manifest path derived" "$(says "same-origin GET /api/datasets/spec_a/cv_0123: MISS")"
check "v1 manifest path derived" "$(says "same-origin GET /api/v1/datasets/spec_a/cv_0123: MISS")"
check "only the cross-origin read sends Origin" "$(is "$(grep -c -- '-H Origin: https://developmentfinance.org' <<<"$calls")" 1)"
check "only one read sends Authorization" "$(is "$(grep -c -- '-H Authorization:' <<<"$calls")" 1)"

# 2. A file the edge already holds answers HIT first, which fails.
run HIT HIT MISS HIT MISS HIT BYPASS DYNAMIC DYNAMIC
check "a first HIT exits 1" "$(is "$status" 1)"
check "a first HIT is named" "$(says "got HIT, want MISS")"

# 3. A cross-origin read served from cache fails.
run MISS HIT MISS HIT MISS HIT HIT DYNAMIC DYNAMIC
check "a cross-origin HIT exits 1" "$(is "$status" 1)"
check "a cross-origin HIT is named" "$(says "with Origin: got HIT, want BYPASS DYNAMIC")"

# 4. An authenticated read served from cache fails.
run MISS HIT MISS HIT MISS HIT BYPASS HIT DYNAMIC
check "an authenticated HIT exits 1" "$(is "$status" 1)"
check "an authenticated HIT is named" "$(says "with Authorization: got HIT, want BYPASS DYNAMIC")"

# 5. A response that shows Cache-Tag to the visitor fails.
run TAG:MISS HIT MISS HIT MISS HIT BYPASS DYNAMIC DYNAMIC
check "a visible Cache-Tag exits 1" "$(is "$status" 1)"
check "a visible Cache-Tag is named" "$(says "shows a Cache-Tag header")"

# 6. A failed request fails its check and the later checks still run: the
# failure is the first manifest read, and all nine requests are sent.
run MISS HIT FAIL HIT MISS HIT BYPASS DYNAMIC DYNAMIC
check "a failed request exits 1" "$(is "$status" 1)"
check "a failed request is named" "$(says "got error, want MISS")"
check "later checks still run" "$(is "$(grep -c '^curl' <<<"$calls")" 9)"

# 7. A usage error exits 2 and sends nothing: a manifest path as file-path,
# then no arguments.
: >"$STUB_LOG"
set +e
out="$("$SCRIPT" /api/datasets/spec_a/cv_0123 "$SELECTOR" 2>&1)"
status=$?
set -e
calls="$(cat "$STUB_LOG")"
check "a manifest path as file-path exits 2" "$(is "$status" 2)"
check "a manifest path as file-path sends nothing" "$(is "$calls" "")"
set +e
out="$("$SCRIPT" 2>&1)"
status=$?
set -e
calls="$(cat "$STUB_LOG")"
check "no arguments exits 2" "$(is "$status" 2)"
check "no arguments names the usage" "$(says "usage: check-edge-cache.sh")"
check "no arguments sends nothing" "$(is "$calls" "")"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed."
    exit 1
fi
echo "All checks passed."
