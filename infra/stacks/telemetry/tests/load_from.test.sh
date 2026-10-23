#!/usr/bin/env bash
# Tests the start day sql/logs_daily.sql computes, load_from, against
# literal sources. Not wired into CI. Run by hand after touching the
# DECLARE and SET statements at the top of the query:
#   infra/stacks/telemetry/tests/load_from.test.sh [project]
#
# Each case runs the query's DECLARE and SET statements as one BigQuery
# script, with ${source}, ${live_source} and requests_daily replaced by
# literal arrays, so the script reads no table and writes nothing. The
# project (default prod-fin-observatory) only bills and runs the jobs, and
# the caller needs bigquery.jobs.create on it.
set -euo pipefail

PROJECT="${1:-prod-fin-observatory}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUTOFF="2026-10-23 19:00:00+00"

# The DECLARE and SET statements, each ending at a line that ends in ";",
# with comment lines dropped.
HEAD="$(awk '
    { buf = buf $0 "\n" }
    /;[[:space:]]*$/ {
        body = buf
        gsub(/(^|\n)[[:space:]]*--[^\n]*/, "", body)
        sub(/^[[:space:]]+/, "", body)
        if (body ~ /^(DECLARE|SET) /) printf "%s\n", body
        buf = ""
    }
' "$DIR/../sql/logs_daily.sql")"
[ -n "$HEAD" ] || {
    echo "load_from.test.sh: no DECLARE or SET statement in logs_daily.sql" >&2
    exit 1
}

timestamps() { echo "(SELECT timestamp FROM UNNEST(ARRAY<TIMESTAMP>[$1]) AS timestamp)"; }
days() { echo "(SELECT day FROM UNNEST(ARRAY<DATE>[$1]) AS day)"; }

failures=0
cases=0
# check <name> <source timestamps> <live_source timestamps> <requests_daily days> <want>
check() {
    local script
    script="$HEAD"
    # shellcheck disable=SC2016 # the patterns are the template's literal placeholders
    script="${script//'`${source}`'/$(timestamps "$2")}"
    # shellcheck disable=SC2016
    script="${script//'`${live_source}`'/$(timestamps "$3")}"
    # shellcheck disable=SC2016
    script="${script//'`${dataset}.requests_daily`'/$(days "$4")}"
    # shellcheck disable=SC2016
    script="${script//'${cutoff}'/$CUTOFF}"
    script="$script
SELECT IFNULL(CAST(load_from AS STRING), 'NULL') AS load_from;"
    local got
    got="$(bq --quiet query --project_id="$PROJECT" --location=EU --use_legacy_sql=false \
        --format=csv <<<"$script" | tail -n 1)"
    cases=$((cases + 1))
    if [ "$got" != "$5" ]; then
        echo "FAIL $1: want $5, got $got" >&2
        failures=$((failures + 1))
    fi
}

BACKFILL="TIMESTAMP '2026-09-23 10:00:00+00', TIMESTAMP '2026-10-23 18:59:00+00'"
LIVE="TIMESTAMP '2026-10-23 18:48:34+00', TIMESTAMP '2026-11-10 12:00:00+00'"

# With no source, nothing loads.
check empty-source "" "" "" NULL
# dfo_logs reaches the cut-off.
check contiguous-empty-table "$BACKFILL" "$LIVE" "" 2026-09-24
check contiguous-daily "$BACKFILL" "$LIVE" "DATE '2026-11-10'" 2026-11-09
check contiguous-floor "$BACKFILL" "$LIVE" "DATE '2026-09-24'" 2026-09-24
# With dfo_logs empty there is nothing to reload, so nothing is deleted.
check live-empty "$BACKFILL" "" "DATE '2026-10-01'" NULL
# Retention has moved dfo_logs' oldest entry past the cut-off.
check gap-outage "$BACKFILL" "TIMESTAMP '2026-12-05 03:00:00+00'" "DATE '2026-11-01'" 2026-12-06
check gap-daily "$BACKFILL" "TIMESTAMP '2026-12-05 03:00:00+00'" "DATE '2026-12-30'" 2026-12-29
check gap-empty-table "$BACKFILL" "TIMESTAMP '2026-12-05 03:00:00+00'" "" 2026-09-24
check gap-on-cutoff-day "$BACKFILL" "TIMESTAMP '2026-10-23 20:00:00+00'" "DATE '2026-10-24'" 2026-10-24

if [ "$failures" -gt 0 ]; then
    echo "load_from.test.sh: $failures of $cases cases failed" >&2
    exit 1
fi
echo "load_from.test.sh: $cases cases passed"
