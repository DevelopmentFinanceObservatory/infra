#!/usr/bin/env bash
# Scenario tests for edge-usage.sh against a stub `curl`, so nothing reaches
# Cloudflare. The stub prints the file in $STUB_RESPONSE, or exits 22 when the
# file says FAIL, and logs its arguments. Nothing runs it automatically; run it
# by hand after touching the script:
#   scripts/edge-usage.test.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/edge-usage.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
export STUB_LOG="$WORK/calls.log" STUB_RESPONSE="$WORK/response"
export CLOUDFLARE_ANALYTICS_API_TOKEN=test-token

cat >"$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$STUB_LOG"
[ "$(cat "$STUB_RESPONSE")" = "FAIL" ] && exit 22
cat "$STUB_RESPONSE"
STUB
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
[ "$(command -v curl)" = "$WORK/bin/curl" ] || { echo "curl stub not first on PATH" >&2; exit 1; }

failures=0
# run <args...>: runs the script on the response already in $STUB_RESPONSE.
run() {
    : >"$STUB_LOG"
    set +e
    out="$("$SCRIPT" "$@" 2>&1)"
    status=$?
    set -e
    calls="$(cat "$STUB_LOG")"
}
check() {
    if [ "$2" = true ]; then
        echo "ok: $1"
    else
        echo "FAIL: $1"
        printf '%s\n' "$out" | sed 's/^/    out: /'
        failures=$((failures + 1))
    fi
}
is() { [ "$1" = "$2" ] && echo true || echo false; }
says() { [[ "$out" == *"$1"* ]] && echo true || echo false; }

group() { # <date> <path> <cacheStatus> <count> [referer]
    jq -n --arg d "$1" --arg p "$2" --arg c "$3" --argjson n "$4" --arg r "${5:-}" \
        '{count: $n, dimensions: ({date: $d, clientRequestPath: $p, cacheStatus: $c} + (if $r != "" then {clientRefererHost: $r} else {} end))}'
}
respond() { # <group json...>
    jq -s '{data: {viewer: {zones: [{httpRequestsAdaptiveGroups: .}]}}}' <<<"$*" >"$STUB_RESPONSE"
}

# 1. Groups fold into day, prefix, kind and cache status; digests and ids drop out.
respond "$(group 2026-11-01 /api/datasets/spec_a/cv_1/files/sha256:aa hit 5)" \
    "$(group 2026-11-01 /api/datasets/spec_a/cv_1/files/sha256:bb hit 7)" \
    "$(group 2026-11-01 /api/v1/datasets/spec_a/cv_1 miss 2)" \
    "$(group 2026-11-01 /api/datasets/spec_a/cv_1/file dynamic 1)"
run 2026-11-01 2026-11-02
check "success exits 0" "$(is "$status" 0)"
check "files fold across digests" "$(says $'2026-11-01\t/api/datasets\tfile\thit\t12')"
check "v1 manifest is its own row" "$(says $'2026-11-01\t/api/v1/datasets\tmanifest\tmiss\t2')"
check "the selector is its own kind" "$(says $'2026-11-01\t/api/datasets\tselector\tdynamic\t1')"
check "the query carries the token and range" "$(is "$([[ "$calls" == *"Bearer test-token"* && "$calls" == *2026-11-02* ]] && echo y)" y)"

# 2. The referer column appears only on request.
respond "$(group 2026-11-01 /api/datasets/spec_a/cv_1 hit 4 example.org)"
set +e
out="$(EDGE_USAGE_BY_REFERER=1 "$SCRIPT" 2026-11-01 2026-11-01 2>&1)"
status=$?
set -e
check "referer run exits 0" "$(is "$status" 0)"
check "referer host is a column" "$(says $'manifest\thit\texample.org\t4')"

# 3. Cloudflare errors exit 1 and are printed.
echo '{"data": null, "errors": [{"message": "unknown field"}]}' >"$STUB_RESPONSE"
run 2026-11-01 2026-11-02
check "a GraphQL error exits 1" "$(is "$status" 1)"
check "a GraphQL error is printed" "$(says "unknown field")"

# 4. A failed request exits 1.
echo FAIL >"$STUB_RESPONSE"
run 2026-11-01 2026-11-02
check "a failed request exits 1" "$(is "$status" 1)"

# 5. An answer at the row limit exits 1.
jq -n '[range(10000) | {count: 1, dimensions: {date: "2026-11-01", clientRequestPath: "/api/datasets/spec_a/cv_1", cacheStatus: "hit"}}]
    | {data: {viewer: {zones: [{httpRequestsAdaptiveGroups: .}]}}}' >"$STUB_RESPONSE"
run 2026-11-01 2026-11-02
check "a cut answer exits 1" "$(is "$status" 1)"

# 6. Usage errors exit 2 and send nothing.
run
check "no arguments exits 2" "$(is "$status" 2)"
run 2026-11-02 2026-11-01
check "a reversed range exits 2" "$(is "$status" 2)"
run yesterday today
check "a non-date exits 2" "$(is "$status" 2)"
check "usage errors send nothing" "$(is "$calls" "")"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed."
    exit 1
fi
echo "All checks passed."
