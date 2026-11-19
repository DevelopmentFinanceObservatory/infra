#!/usr/bin/env bash
# Checks the cache ruleset in infra/stacks/edge/cloudflare_rules.tf against
# the live edge, after an apply. It sends GETs only and changes nothing.
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
#   4. The /file selector answers DYNAMIC.
#   5. No response shows the Cache-Tag header, which Cloudflare strips.
#
# With --after-purge, run after purging the version's cache tag
# (infra/dfo-prod/edge/README.md, "Revoking a dataset version"): it reads each
# variant of the file and the manifest, and the v1 manifest, once and expects
# MISS for every one.
#
# The file must not have been read through the edge since its last purge, or
# the first read is already a HIT. Pick a digest from a version minted for the
# check, or purge its content version first (infra/dfo-prod/edge/README.md,
# "Revoking a dataset version").
#
# Usage: check-edge-cache.sh [--after-purge] <file-path> <selector-path>
#   file-path      /api/datasets/spec_<id>/cv_<hex>/files/<digest>, from a
#                  manifest's artifact url
#   selector-path  /api/datasets/spec_<id>/cv_<hex>/file?format=<format>
# EDGE_BASE_URL overrides https://developmentfinance.org.
# Exit: 0 when every check passes, 1 when one fails, 2 on a usage error.
set -euo pipefail

usage="usage: check-edge-cache.sh [--after-purge] <file-path> <selector-path>"
after_purge=false
if [ "${1:-}" = "--after-purge" ]; then
    after_purge=true
    shift
fi
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

# status <path> [curl args...]: GETs base+path, discards the body, and prints
# cf-cache-status on one line, or "none" when the response has none, then the
# Access-Control-Allow-Origin value on a second line, or "none". A response
# with a Cache-Tag header counts as a failure.
status() {
    local path="$1" headers
    shift
    headers="$(curl -sS --fail-with-body -o /dev/null -D - "$@" "$base$path")" || {
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

origins=("" "https://developmentfinance.org" "https://preview.developmentfinance.org")
for path in "$file_path" "$manifest_path"; do
    for origin in "${origins[@]}"; do
        tag="${origin:-no Origin}"
        if [ "$after_purge" = true ]; then
            read_variant "GET $path after purge, $tag" "$path" "$origin" MISS
        else
            read_variant "first GET $path, $tag" "$path" "$origin" MISS
            read_variant "second GET $path, $tag" "$path" "$origin" HIT
        fi
    done
done

if [ "$after_purge" = true ]; then
    read_variant "GET $manifest_v1_path after purge, no Origin" "$manifest_v1_path" "" MISS
else
    read_variant "first GET $manifest_v1_path, no Origin" "$manifest_v1_path" "" MISS
    read_variant "second GET $manifest_v1_path, no Origin" "$manifest_v1_path" "" HIT

    # The credential is a placeholder; the edge decides on the header alone.
    auth="$(status "$manifest_v1_path" -H "Authorization: Bearer edge-cache-check" | head -n 1)" || auth="error"
    expect "GET $manifest_v1_path with Authorization" "$auth" BYPASS DYNAMIC

    # The selector answers a 302, which curl does not follow without -L.
    selector="$(status "$selector_path" | head -n 1)" || selector="error"
    expect "GET $selector_path" "$selector" DYNAMIC
fi

echo "$checks checks, $failures failed."
[ "$checks" -gt 0 ] && [ "$failures" -eq 0 ]
