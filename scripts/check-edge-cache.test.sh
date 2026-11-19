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

# run <queue entries...>: queues one response per entry, then runs the script
# on FILE and SELECTOR, with ARGS (default none) before them. An entry is
# "FAIL" for a curl failure, "TAG:<status>" for a response carrying
# Cache-Tag, "<status>" for a response with no Access-Control-Allow-Origin, or
# "<status>@<origin>" for one that allows that origin.
ARGS=()
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
        *@*) printf 'HTTP/2 200\nCF-Cache-Status: %s\nAccess-Control-Allow-Origin: %s\n\n' "${s%%@*}" "${s#*@}" >"$STUB_QUEUE/$n" ;;
        *) printf 'HTTP/2 200\nCF-Cache-Status: %s\n\n' "$s" >"$STUB_QUEUE/$n" ;;
        esac
    done
    set +e
    out="$("$SCRIPT" ${ARGS[@]+"${ARGS[@]}"} "$FILE" "$SELECTOR" 2>&1)"
    status=$?
    set -e
    calls="$(cat "$STUB_LOG")"
}

APEX=https://developmentfinance.org
PREVIEW=https://preview.developmentfinance.org

# variants <status...>: the six reads of one path, in order, each variant's
# status taken from the arguments, with the Access-Control-Allow-Origin its
# request's Origin calls for.
variants() {
    VARIANTS=("$1" "$2" "$3@$APEX" "$4@$APEX" "$5@$PREVIEW" "$6@$PREVIEW")
}
happy() {
    variants MISS HIT MISS HIT MISS HIT
    HAPPY=("${VARIANTS[@]}" "${VARIANTS[@]}" MISS HIT BYPASS DYNAMIC DYNAMIC)
}

failures=0

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
# the same path under /api/v1/datasets, the file and manifest are each read
# twice per Origin value, and only one request sends Authorization.
happy
run "${HAPPY[@]}"
check "expected statuses exit 0" "$(is "$status" 0)"
check "all checks counted" "$(says "31 checks, 0 failed.")"
check "manifest path derived" "$(says "first GET /api/datasets/spec_a/cv_0123, no Origin: MISS")"
check "v1 manifest path derived" "$(says "first GET /api/v1/datasets/spec_a/cv_0123, no Origin: MISS")"
check "each approved origin is sent on four reads" "$(is "$(grep -c -- "-H Origin: $APEX " <<<"$calls") $(grep -c -- "-H Origin: $PREVIEW " <<<"$calls")" "4 4")"
check "only one read sends Authorization" "$(is "$(grep -c -- '-H Authorization:' <<<"$calls")" 1)"
check "only one read is a HEAD" "$(is "$(grep -c -- ' -I' <<<"$calls")" 1)"

# 2. A file the edge already holds answers HIT first, which fails.
happy
HAPPY[0]=HIT
run "${HAPPY[@]}"
check "a first HIT exits 1" "$(is "$status" 1)"
check "a first HIT is named" "$(says "got HIT, want MISS")"

# 3. A cross-origin variant never stored fails its HIT.
happy
HAPPY[3]="BYPASS@$APEX"
run "${HAPPY[@]}"
check "a cross-origin BYPASS exits 1" "$(is "$status" 1)"
check "a cross-origin BYPASS is named" "$(says "second GET $FILE, $APEX: got BYPASS, want HIT")"

# 4. A response with another origin's Access-Control-Allow-Origin fails, and
# so does one that has none for a request with an Origin or one that has it
# for a request with none.
happy
HAPPY[4]="MISS@$APEX"
run "${HAPPY[@]}"
check "a wrong Access-Control-Allow-Origin exits 1" "$(is "$status" 1)"
check "a wrong Access-Control-Allow-Origin is named" "$(says "$PREVIEW Access-Control-Allow-Origin: got $APEX, want $PREVIEW")"
happy
HAPPY[2]=MISS
run "${HAPPY[@]}"
check "a missing Access-Control-Allow-Origin exits 1" "$(is "$status" 1)"
check "a missing Access-Control-Allow-Origin is named" "$(says "got none, want $APEX")"
happy
HAPPY[0]="MISS@$APEX"
run "${HAPPY[@]}"
check "an Access-Control-Allow-Origin with no Origin exits 1" "$(is "$status" 1)"

# 5. An authenticated read served from cache fails.
happy
HAPPY[14]=HIT
run "${HAPPY[@]}"
check "an authenticated HIT exits 1" "$(is "$status" 1)"
check "an authenticated HIT is named" "$(says "with Authorization: got HIT, want BYPASS DYNAMIC")"

# 6. A HEAD served from cache fails.
happy
HAPPY[15]=HIT
run "${HAPPY[@]}"
check "a cached HEAD exits 1" "$(is "$status" 1)"
check "a cached HEAD is named" "$(says "HEAD /api/v1/datasets/spec_a/cv_0123: got HIT, want DYNAMIC")"

# 7. A response that shows Cache-Tag to the visitor fails.
happy
HAPPY[0]=TAG:MISS
run "${HAPPY[@]}"
check "a visible Cache-Tag exits 1" "$(is "$status" 1)"
check "a visible Cache-Tag is named" "$(says "shows a Cache-Tag header")"

# 8. A failed request fails its check and the later checks still run: the
# failure is the first manifest read, and all seventeen requests are sent.
happy
HAPPY[6]=FAIL
run "${HAPPY[@]}"
check "a failed request exits 1" "$(is "$status" 1)"
check "a failed request is named" "$(says "got error, want MISS")"
check "later checks still run" "$(is "$(grep -c '^curl' <<<"$calls")" 17)"

# 9. After a purge, every variant answers MISS: seven reads, three sending
# each approved Origin value for the file and manifest only.
ARGS=(--after-purge)
variants MISS MISS MISS MISS MISS MISS
run MISS MISS@$APEX MISS@$PREVIEW MISS MISS@$APEX MISS@$PREVIEW MISS
check "after-purge MISS on every variant exits 0" "$(is "$status" 0)"
check "after-purge sends seven reads" "$(is "$(grep -c '^curl' <<<"$calls")" 7)"
run MISS MISS@$APEX HIT MISS MISS@$APEX MISS@$PREVIEW MISS
check "after-purge HIT exits 1" "$(is "$status" 1)"
check "after-purge HIT is named" "$(says "got HIT, want MISS")"
ARGS=()

# 10. A usage error exits 2 and sends nothing: a manifest path as file-path,
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
