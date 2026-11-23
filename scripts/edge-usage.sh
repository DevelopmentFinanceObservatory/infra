#!/usr/bin/env bash
# Estimates reads of the dataset paths at the Cloudflare edge, per UTC day, path
# kind and cache status, with the bytes served. It queries Cloudflare's GraphQL
# Analytics API and changes nothing. Requests that Cloudflare answers from its
# cache never reach the website, so its request log undercounts them; this
# estimate includes them.
# httpRequestsAdaptiveGroups is an adaptive dataset, so Cloudflare samples it at
# a rate the caller cannot set
# (https://developers.cloudflare.com/analytics/graphql-api/sampling/) and the
# counts and bytes are estimates scaled up from the sample. Use them for cache
# hit share and bytes served from the edge. Keep them apart from dataset uses
# (dfo-apis delivery lines) and never add the two. The sampled column is the
# avg { sampleInterval } of each group
# (https://developers.cloudflare.com/analytics/graphql-api/migration-guides/zone-analytics-colos/):
# 1 means unsampled, 10 means one request in ten was sampled. Where rows fold
# together it is the request-weighted mean, to two decimals.
#
# Usage: edge-usage.sh <start_date> <end_date>
#   edge-usage.sh 2026-11-01 2026-11-18
# Dates are UTC days, YYYY-MM-DD, both inclusive. Adaptive datasets keep at
# least 31 days, so a start date older than that returns nothing.
# Output is tab-separated with a header row: day, prefix (/api/datasets or /api/v1/datasets),
# kind (file, derived_file for a derived frame's file, manifest, or selector for
# the /file route and any other path),
# cache status, [referer host,] requests, bytes (edgeResponseBytes) and sampled.
# EDGE_USAGE_BY_REFERER=1 adds the clientRefererHost dimension and column. The
# field is not documented on the pages the README cites, so check it against
# the schema (introspection) before relying on it; Cloudflare rejects an
# unknown field with an error, which this script prints.
# CLOUDFLARE_ANALYTICS_API_TOKEN overrides the keychain service
# dfo-cloudflare-edge-analytics (Account Analytics Read, or Analytics Read on
# the zone). EDGE_ZONE_ID overrides the developmentfinance.org zone.
# Exit: 0 on success, 1 on an API error or an answer cut at the row limit,
# 2 on a usage error.
set -euo pipefail

usage="usage: edge-usage.sh <start_date> <end_date>"
[ $# -eq 2 ] || {
    echo "$usage" >&2
    exit 2
}
start="$1" end="$2"
for d in "$start" "$end"; do
    [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
        echo "$usage (dates are YYYY-MM-DD): $d" >&2
        exit 2
    }
done
[[ ! "$start" > "$end" ]] || {
    echo "start date $start is after end date $end" >&2
    exit 2
}

zone="${EDGE_ZONE_ID:-e837f8819d4b16dce14e17cbe6ba3716}"
token="${CLOUDFLARE_ANALYTICS_API_TOKEN:-$(security find-generic-password -s dfo-cloudflare-edge-analytics -w)}"
limit=10000
referer_field=""
[ "${EDGE_USAGE_BY_REFERER:-}" = 1 ] && referer_field="clientRefererHost"

query="query(\$zone: string, \$start: Date, \$end: Date) {
  viewer { zones(filter: {zoneTag: \$zone}) {
    httpRequestsAdaptiveGroups(limit: $limit, orderBy: [date_ASC], filter: {
      date_geq: \$start, date_leq: \$end, requestSource: \"eyeball\", clientRequestHTTPMethodName: \"GET\",
      OR: [{clientRequestPath_like: \"/api/datasets/%\"}, {clientRequestPath_like: \"/api/v1/datasets/%\"}]
    }) { count sum { edgeResponseBytes } avg { sampleInterval } dimensions { date clientRequestPath cacheStatus $referer_field } }
  } }
}"

body="$(jq -n --arg q "$query" --arg zone "$zone" --arg s "$start" --arg e "$end" \
    '{query: $q, variables: {zone: $zone, start: $s, end: $e}}')"
response="$(curl -sS --fail-with-body https://api.cloudflare.com/client/v4/graphql \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$body")" || {
    echo "the GraphQL request failed: $response" >&2
    exit 1
}
if jq -e '(.errors // []) | length > 0' >/dev/null <<<"$response"; then
    echo "Cloudflare returned errors:" >&2
    jq -c '.errors' <<<"$response" >&2
    exit 1
fi
rows="$(jq '.data.viewer.zones[0].httpRequestsAdaptiveGroups // empty' <<<"$response")"
[ -n "$rows" ] || {
    echo "the response holds no httpRequestsAdaptiveGroups for zone $zone" >&2
    exit 1
}
[ "$(jq length <<<"$rows")" -lt "$limit" ] || {
    echo "the answer reached the $limit-row limit, so counts are cut; query a shorter range" >&2
    exit 1
}

# The table's header row, then one row per group.
if [ "${EDGE_USAGE_BY_REFERER:-}" = 1 ]; then
    printf 'day\tprefix\tkind\tcache_status\treferer_host\trequests\tbytes\tsampled\n'
else
    printf 'day\tprefix\tkind\tcache_status\trequests\tbytes\tsampled\n'
fi
jq -r --arg by_referer "${EDGE_USAGE_BY_REFERER:-}" '
    def kind: if test("^/api(/v1)?/datasets/derived/.*/files/") then "derived_file"
        elif test("/files/") then "file"
        elif test("^/api(/v1)?/datasets/spec_[^/]*/cv_[^/]*$") then "manifest"
        else "selector" end;
    map({day: .dimensions.date, prefix: (.dimensions.clientRequestPath | if startswith("/api/v1/") then "/api/v1/datasets" else "/api/datasets" end),
         kind: (.dimensions.clientRequestPath | kind), cache: .dimensions.cacheStatus,
         referer: (.dimensions.clientRefererHost // ""), count: .count,
         bytes: (.sum.edgeResponseBytes // 0), weighted: (.count * (.avg.sampleInterval // 1))})
    | group_by([.day, .prefix, .kind, .cache, .referer])
    | map(.[0] + {count: (map(.count) | add), bytes: (map(.bytes) | add), weighted: (map(.weighted) | add)})
    | sort_by([.day, .prefix, .kind, .cache, .referer])[]
    | .sampled = (if .count > 0 then (.weighted / .count * 100 | round) else 100 end | "\(. / 100 | floor).\((. % 100) | tostring | if length < 2 then "0" + . else . end)")
    | if $by_referer == "1" then [.day, .prefix, .kind, .cache, .referer, .count, .bytes, .sampled] else [.day, .prefix, .kind, .cache, .count, .bytes, .sampled] end
    | @tsv' <<<"$rows"
