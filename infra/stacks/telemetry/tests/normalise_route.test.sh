#!/usr/bin/env bash
# Tests sql/normalise_route.sql against route_sample.tsv. Not wired into CI.
# Run by hand after touching the function or the fixture:
#   infra/stacks/telemetry/tests/normalise_route.test.sh [project]
#
# The function body runs as a temporary function in one BigQuery query over
# literal inputs, so the query reads no table and scans no bytes. The project
# (default prod-fin-observatory) only bills and runs the job, and the caller
# needs bigquery.jobs.create on it.
set -euo pipefail

PROJECT="${1:-prod-fin-observatory}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BODY="$(cat "$DIR/../sql/normalise_route.sql")"

# One STRUCT literal per fixture line, quotes and backslashes escaped.
CASES="$(awk -F '\t' '
    /^#/ || NF == 0 { next }
    {
        for (i = 1; i <= 2; i++) { gsub(/\\/, "\\\\", $i); gsub(/'\''/, "\\'\''", $i) }
        printf "%sSTRUCT('\''%s'\'' AS url, '\''%s'\'' AS want)", (n++ ? ",\n" : ""), $1, $2
    }
' "$DIR/route_sample.tsv")"
[ -n "$CASES" ] || {
    echo "normalise_route.test.sh: no cases in route_sample.tsv" >&2
    exit 1
}

QUERY="CREATE TEMP FUNCTION normalise_route(url STRING) RETURNS STRING AS (
$BODY
);
WITH cases AS (SELECT url, want, normalise_route(url) AS got FROM UNNEST([
$CASES
]))
SELECT 'cases' AS url, CAST(COUNT(*) AS STRING) AS want, '' AS got FROM cases
UNION ALL
SELECT url, want, got FROM cases WHERE got IS DISTINCT FROM want"

OUT="$(bq query --project_id="$PROJECT" --location=EU --use_legacy_sql=false \
    --format=csv --max_rows=10000 "$QUERY")"

TOTAL="$(awk -F, '$1 == "cases" { print $2 }' <<<"$OUT")"
FAILURES="$(awk -F, 'NR > 1 && $1 != "cases"' <<<"$OUT")"
[ "${TOTAL:-0}" -gt 0 ] || {
    echo "normalise_route.test.sh: the query ran no cases" >&2
    exit 1
}
if [ -n "$FAILURES" ]; then
    echo "normalise_route.test.sh: url,want,got for each failing case:" >&2
    echo "$FAILURES" >&2
    exit 1
fi
echo "normalise_route.test.sh: $TOTAL cases passed"
