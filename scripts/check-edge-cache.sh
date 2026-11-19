#!/usr/bin/env bash
# Checks the cache ruleset in infra/stacks/edge/cloudflare_rules.tf against
# the live edge, after an apply. It sends GETs only and changes nothing.
#
#   1. A pinned dataset file, read twice with no Origin header, answers
#      cf-cache-status MISS and then HIT.
#   2. Its manifest, read the same way under /api/datasets/ and again under
#      /api/v1/datasets/, answers MISS and then HIT on each prefix.
#   3. The same file read with Origin: https://developmentfinance.org answers
#      BYPASS or DYNAMIC, so a cross-origin response is never stored.
#   4. The v1 manifest read with an Authorization header answers BYPASS or
#      DYNAMIC, so an authenticated response is never stored.
#   5. The /file selector answers DYNAMIC.
#   6. No response shows the Cache-Tag header, which Cloudflare strips.
#
# The file must not have been read through the edge since its last purge, or
# the first read is already a HIT. Pick a digest from a version minted for the
# check, or purge its content version first (infra/dfo-prod/edge/README.md,
# "Revoking a dataset version").
#
# Usage: check-edge-cache.sh <file-path> <selector-path>
#   file-path      /api/datasets/spec_<id>/cv_<hex>/files/<digest>, from a
#                  manifest's artifact url
#   selector-path  /api/datasets/spec_<id>/cv_<hex>/file?format=<format>
# EDGE_BASE_URL overrides https://developmentfinance.org.
# Exit: 0 when every check passes, 1 when one fails, 2 on a usage error.
set -euo pipefail

usage="usage: check-edge-cache.sh <file-path> <selector-path>"
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
# cf-cache-status, or "none" when the response has none. A response with a
# Cache-Tag header counts as a failure.
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
    awk -F': *' 'tolower($1) == "cf-cache-status" { gsub(/\r/, "", $2); print toupper($2); found = 1 }
        END { if (!found) print "none" }' <<<"$headers"
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

for path in "$file_path" "$manifest_path" "$manifest_v1_path"; do
    first="$(status "$path")" || first="error"
    second="$(status "$path")" || second="error"
    expect "first same-origin GET $path" "$first" MISS
    expect "second same-origin GET $path" "$second" HIT
done

cross="$(status "$file_path" -H "Origin: https://developmentfinance.org")" || cross="error"
expect "GET $file_path with Origin" "$cross" BYPASS DYNAMIC

# The credential is a placeholder; the edge decides on the header alone.
auth="$(status "$manifest_v1_path" -H "Authorization: Bearer edge-cache-check")" || auth="error"
expect "GET $manifest_v1_path with Authorization" "$auth" BYPASS DYNAMIC

# The selector answers a 302, which curl does not follow without -L.
selector="$(status "$selector_path")" || selector="error"
expect "GET $selector_path" "$selector" DYNAMIC

echo "$checks checks, $failures failed."
[ "$checks" -gt 0 ] && [ "$failures" -eq 0 ]
