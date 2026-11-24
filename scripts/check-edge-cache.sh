#!/usr/bin/env bash
# Checks the cache ruleset in infra/stacks/edge/cloudflare_rules.tf against
# the live edge, after an apply. It sends GETs and one HEAD, and changes
# nothing.
#
#   1. A pinned dataset file and its manifest, each read twice with no Origin,
#      twice with Origin: https://developmentfinance.org, and twice with
#      Origin: https://preview.developmentfinance.org, answer cf-cache-status
#      MISS and then HIT for each variant. Each response's
#      Access-Control-Allow-Origin equals its request's Origin, and is absent
#      when the request has none.
#   2. The manifest, read with no Origin twice under /api/v1/datasets/,
#      answers MISS and then HIT.
#   3. The v1 manifest read with an Authorization header answers BYPASS or
#      DYNAMIC, so an authenticated response is never stored.
#   4. A HEAD of the v1 manifest, cached by the GETs in check 2, answers
#      DYNAMIC, so the edge serves and stores GET only.
#   5. The /file selector answers DYNAMIC.
#   6. No response shows the Cache-Tag header, which Cloudflare strips.
#
# With --after-purge, run after purging the version's cache tag
# (infra/dfo-prod/edge/README.md, "Revoking a dataset version"): it reads each
# variant of the file and the manifest, and the v1 manifest, once and expects
# MISS for every one.
#
# With --revoked, run after revoking a version and purging its cache tag: it
# reads each variant of the file and the manifest, and the v1 manifest, once,
# and expects the answer to be 410 with a cf-cache-status other than HIT or
# STALE, so no revoked copy is served from the edge.
#
# The file must not have been read through the edge since its last purge, or
# the first read is already a HIT. Pick a digest from a version minted for the
# check, or purge its content version first (infra/dfo-prod/edge/README.md,
# "Revoking a dataset version").
#
# Usage: check-edge-cache.sh [--after-purge | --revoked] <file-path> <selector-path>
#   file-path      /api/datasets/spec_<id>/cv_<hex>/files/<digest>, from a
#                  manifest's artifact url
#   selector-path  /api/datasets/spec_<id>/cv_<hex>/file?format=<format>
# EDGE_BASE_URL overrides https://developmentfinance.org.
# Exit: 0 when every check passes, 1 when one fails, 2 on a usage error.
set -euo pipefail

usage="usage: check-edge-cache.sh [--after-purge | --revoked] <file-path> <selector-path>"
after_purge=false
revoked=false
case "${1:-}" in
--after-purge)
    after_purge=true
    shift
    ;;
--revoked)
    revoked=true
    shift
    ;;
esac
[ $# -eq 2 ] || {
    echo "$usage" >&2
    exit 2
}
file_path="$1"
selector_path="$2"
base="${EDGE_BASE_URL:-https://developmentfinance.org}"

case "$file_path" in
/api/datasets/spec_*/cv_*/files/*) ;;
*)
    echo "file-path must look like /api/datasets/spec_<id>/cv_<hex>/files/<digest>: $file_path" >&2
    exit 2
    ;;
esac
manifest_path="${file_path%/files/*}"
manifest_v1_path="/api/v1/datasets/${manifest_path#/api/datasets/}"

failures=0
checks=0

# status [--any-status] <path> [curl args...]: GETs base+path, discards the
# body, and prints cf-cache-status on one line, or "none" when the response has
# none, then the Access-Control-Allow-Origin value on a second line, or "none".
# A response other than 2xx or 3xx counts as a failure unless --any-status is
# given. A response with a Cache-Tag header counts as a failure.
status() {
    local fail=--fail-with-body path headers
    if [ "$1" = --any-status ]; then
        fail=
        shift
    fi
    path="$1"
    shift
    headers="$(curl -sS $fail -o /dev/null -D - "$@" "$base$path")" || {
        echo "FAIL: GET $path did not answer 2xx or 3xx" >&2
        return 1
    }
    if grep -qi '^cache-tag:' <<<"$headers"; then
        echo "FAIL: GET $path shows a Cache-Tag header to the visitor" >&2
        return 1
    fi
    awk '
        { line = $0; gsub(/\r/, "", line); name = tolower(line); sub(/:.*/, "", name); sub(/^[^:]*: */, "", line) }
        name == "cf-cache-status" { cache = toupper(line) }
        name == "access-control-allow-origin" { acao = line }
        END { print (cache == "" ? "none" : cache); print (acao == "" ? "none" : acao) }' <<<"$headers"
}

# expect <label> <got> <allowed...>: passes when got is one of allowed.
expect() {
    local label="$1" got="$2" want
    shift 2
    checks=$((checks + 1))
    for want in "$@"; do
        if [ "$got" = "$want" ]; then
            echo "ok: $label: $got"
            return 0
        fi
    done
    echo "FAIL: $label: got $got, want $*"
    failures=$((failures + 1))
}

# read <label> <path> <origin> <want...>: GETs path, with an Origin header
# unless origin is empty, and expects cf-cache-status to be one of want and
# Access-Control-Allow-Origin to equal origin, or be absent for no origin.
read_variant() {
    local label="$1" path="$2" origin="$3" got acao want_acao out
    shift 3
    if [ -n "$origin" ]; then
        out="$(status "$path" -H "Origin: $origin")" || out=$'error\nerror'
        want_acao="$origin"
    else
        out="$(status "$path")" || out=$'error\nerror'
        want_acao="none"
    fi
    { read -r got; read -r acao; } <<<"$out"
    expect "$label" "$got" "$@"
    expect "$label Access-Control-Allow-Origin" "$acao" "$want_acao"
}

# revoked_read <label> <path> <origin>: GETs path, with an Origin header
# unless origin is empty, and expects the HTTP status 410 and a
# cf-cache-status that is neither HIT nor STALE.
revoked_read() {
    local label="$1" path="$2" origin="$3" headers code cache args=()
    [ -z "$origin" ] || args=(-H "Origin: $origin")
    checks=$((checks + 1))
    headers="$(curl -sS -o /dev/null -D - ${args[@]+"${args[@]}"} "$base$path")" || {
        echo "FAIL: $label: request failed"
        failures=$((failures + 1))
        return 0
    }
    if grep -qi '^cache-tag:' <<<"$headers"; then
        echo "FAIL: $label: shows a Cache-Tag header to the visitor"
        failures=$((failures + 1))
        return 0
    fi
    code="$(awk 'NR == 1 { print $2 }' <<<"$headers" | tr -d '\r')"
    cache="$(awk '{ sub(/\r$/, "") } tolower($1) == "cf-cache-status:" { print toupper($2) }' <<<"$headers")"
    cache="${cache:-none}"
    if [ "$code" = 410 ] && [ "$cache" != HIT ] && [ "$cache" != STALE ]; then
        echo "ok: $label: 410, cache $cache"
    else
        echo "FAIL: $label: got ${code:-no status}, cache $cache, want 410 and not HIT or STALE"
        failures=$((failures + 1))
    fi
}

origins=("" "https://developmentfinance.org" "https://preview.developmentfinance.org")
for path in "$file_path" "$manifest_path"; do
    for origin in "${origins[@]}"; do
        tag="${origin:-no Origin}"
        if [ "$revoked" = true ]; then
            revoked_read "GET $path revoked, $tag" "$path" "$origin"
        elif [ "$after_purge" = true ]; then
            read_variant "GET $path after purge, $tag" "$path" "$origin" MISS
        else
            read_variant "first GET $path, $tag" "$path" "$origin" MISS
            read_variant "second GET $path, $tag" "$path" "$origin" HIT
        fi
    done
done

if [ "$revoked" = true ]; then
    revoked_read "GET $manifest_v1_path revoked, no Origin" "$manifest_v1_path" ""
elif [ "$after_purge" = true ]; then
    read_variant "GET $manifest_v1_path after purge, no Origin" "$manifest_v1_path" "" MISS
else
    read_variant "first GET $manifest_v1_path, no Origin" "$manifest_v1_path" "" MISS
    read_variant "second GET $manifest_v1_path, no Origin" "$manifest_v1_path" "" HIT

    # The credential is a placeholder; the edge decides on the header alone.
    auth="$(status "$manifest_v1_path" -H "Authorization: Bearer edge-cache-check" | head -n 1)" || auth="error"
    expect "GET $manifest_v1_path with Authorization" "$auth" BYPASS DYNAMIC

    # dfo-apis answers HEAD on these routes with 405; the check is on the edge,
    # which must pass HEAD to the origin, whatever the origin answers.
    head="$(status --any-status "$manifest_v1_path" -I | head -n 1)" || head="error"
    expect "HEAD $manifest_v1_path" "$head" DYNAMIC

    # The selector answers a 302, which curl does not follow without -L.
    selector="$(status "$selector_path" | head -n 1)" || selector="error"
    expect "GET $selector_path" "$selector" DYNAMIC
fi

echo "$checks checks, $failures failed."
[ "$checks" -gt 0 ] && [ "$failures" -eq 0 ]
