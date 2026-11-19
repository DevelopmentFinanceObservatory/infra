#!/usr/bin/env bash
# Checks that the Cloudflare Logpush job in infra/stacks/edge/cloudflare_logpush.tf
# delivers dataset-read lines to its bucket. It reads with gcloud storage and
# changes nothing.
#
#   1. Lists the batches under http_requests/<YYYYMMDD>/ for the UTC days the
#      last hour spans, and reads those whose name ends in the last hour.
#      Logpush names a batch <start>_<end>_<hash>.log.gz.
#   2. Counts the lines whose EdgeStartTimestamp is in the last hour and whose
#      ClientRequestPath starts /api/datasets/ or /api/v1/datasets/, and prints
#      them by CacheCacheStatus.
#   3. Fails when there are none, or when any of them lacks CacheCacheStatus or
#      ClientIP.
#   4. Fails when a day directory older than two days still holds anything but
#      the ownership challenge file, since the bucket's delete rule should have
#      removed every batch after one day.
#
# Usage: check-edge-logpush.sh <bucket>
#   bucket  the telemetry stack's edge_logs_bucket output, without gs://
# CHECK_EDGE_LOGPUSH_NOW overrides the current time, in Unix seconds.
# Exit: 0 when every check passes, 1 when one fails, 2 on a usage error.
set -euo pipefail

usage="usage: check-edge-logpush.sh <bucket>"
[ $# -eq 1 ] || {
    echo "$usage" >&2
    exit 2
}
bucket="$1"
[[ "$bucket" =~ ^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$ ]] || {
    echo "$usage (a bucket name, without gs://): $bucket" >&2
    exit 2
}

now="${CHECK_EDGE_LOGPUSH_NOW:-$(date -u +%s)}"
[[ "$now" =~ ^[0-9]+$ ]] || {
    echo "CHECK_EDGE_LOGPUSH_NOW must be Unix seconds: $now" >&2
    exit 2
}
since=$((now - 3600))
day() { jq -rn --argjson t "$1" '$t | strftime("%Y%m%d")'; }
root="gs://$bucket/http_requests"

# ls_or_empty <url>: the objects gcloud lists, or nothing when it matches none.
ls_or_empty() {
    local out
    if out="$(gcloud storage ls "$1" 2>&1)"; then
        printf '%s\n' "$out"
    elif [[ "$out" == *"matched no objects"* ]]; then
        return 0
    else
        echo "gcloud storage ls $1 failed: $out" >&2
        exit 1
    fi
}

days="$(printf '%s\n%s\n' "$(day "$since")" "$(day "$now")" | sort -u)"
listed=""
while read -r d; do
    listed="$listed$(ls_or_empty "$root/$d/*.log.gz")"$'\n'
done <<<"$days"

# Batches whose end time, the second field of the name, is in the last hour.
# A name that does not parse is read too, so no batch is skipped.
listed="$(grep -v '^$' <<<"$listed" || true)"
recent=""
[ -z "$listed" ] || recent="$(jq -Rr --argjson since "$since" '
    . as $url | ($url | split("/") | last | split("_")) as $parts
    | (try ($parts[1] | strptime("%Y%m%dT%H%M%SZ") | mktime) catch null) as $end
    | select($end == null or $end >= $since) | $url' <<<"$listed")"
batches=0
[ -z "$recent" ] || batches="$(grep -c . <<<"$recent")"
echo "batches ending in the last hour: $batches"

lines=""
if [ "$batches" -gt 0 ]; then
    # Logpush writes gzip with Content-Encoding: gzip, and GCS may decompress
    # in transit, so gzip -f passes plain text through unchanged.
    # shellcheck disable=SC2086 # one URL per word
    lines="$(gcloud storage cat $recent | gzip -dcf)"
fi

summary="$(jq -sc --argjson since "$since" '
    map(select((.EdgeStartTimestamp | try fromdateiso8601 catch 0) >= $since
        and ((.ClientRequestPath // "") | startswith("/api/datasets/") or startswith("/api/v1/datasets/"))))
    | {total: length,
       missing: map(select(has("CacheCacheStatus") and has("ClientIP") | not)) | length,
       by_status: (group_by(.CacheCacheStatus) | map([(.[0].CacheCacheStatus // "(absent)"), length]))}' <<<"$lines")" || {
    echo "FAIL: a batch holds a line that is not JSON" >&2
    exit 1
}

total="$(jq .total <<<"$summary")"
missing="$(jq .missing <<<"$summary")"
echo "dataset-read lines in the last hour: $total"
if [ "$total" -gt 0 ]; then
    printf 'cache_status\tlines\n'
    jq -r '.by_status[] | @tsv' <<<"$summary"
fi

failed=0
if [ "$total" -eq 0 ]; then
    echo "FAIL: no dataset-read lines in the last hour" >&2
    failed=1
fi
if [ "$missing" -gt 0 ]; then
    echo "FAIL: $missing line(s) lack CacheCacheStatus or ClientIP" >&2
    failed=1
fi

# Day directories older than two days, by name, should hold only the
# ownership challenge.
cutoff="$(day $((now - 2 * 86400)))"
dirs="$(ls_or_empty "$root/")"
stale=""
while read -r dir; do
    [ -n "$dir" ] || continue
    d="$(basename "$dir")"
    [[ "$d" =~ ^[0-9]{8}$ && "$d" < "$cutoff" ]] || continue
    contents="$(ls_or_empty "$dir")"
    stale="$stale$(grep -v -e '^$' -e '/ownership-challenge-[^/]*\.txt$' <<<"$contents" || true)"$'\n'
done <<<"$dirs"
stale="$(grep -v '^$' <<<"$stale" || true)"
if [ -n "$stale" ]; then
    echo "FAIL: objects older than two days, past the bucket's one-day delete rule:" >&2
    printf '%s\n' "$stale" | sed 's/^/    /' >&2
    failed=1
fi

exit "$failed"
