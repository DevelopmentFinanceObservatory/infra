#!/usr/bin/env bash
# Tests the ga4-user-ranges workflow's queries (ga4_user_ranges.tf):
# sql/ga4_user_ranges_requests.sql for fixed dates, and
# sql/ga4_user_ranges_rows.sql over literal Data API replies. Not wired into
# CI. Run by hand after touching either query:
#   infra/stacks/telemetry/tests/ga4_user_ranges.test.sh [project]
#
# The queries read only their parameters, so they scan no bytes. With today
# 2026-10-24, yesterday is 2026-10-23, a Friday: last_28 starts 2026-09-26,
# before the floor, the third week ends at yesterday, and the month starts on
# 2026-10-01. With data from 2026-10-05 every range is asked for, seven in
# two requests. With data from 2026-10-14 the week ending 2026-10-11 is left
# out, as GA4 has no row for it.
#
# On Tuesday 2026-10-27, with GA4's data ending on Sunday 2026-10-25, the day
# before yesterday, every range ends on 2026-10-25 and the week starting
# Monday 2026-10-26 is left out. On Monday 2026-11-02, with data ending on
# 2026-10-31, November is left out the same way.
#
# The replies to the six ranges asked for in the second case put the first
# request's rows out of order, and give the second request, cut to one
# range, no dateRange dimension, as the Data API does. A missing or repeated
# row stops the rows query, and a row of zeros, which the Data API returns for
# a range with no users since the requests set keepEmptyRows, loads as zeros.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"
REQUESTS="$(cat "$DIR/../sql/ga4_user_ranges_requests.sql")"
ROWS="$(cat "$DIR/../sql/ga4_user_ranges_rows.sql")"

# param_query <query> <bq --parameter value>...: runs <query> with the named
# parameters and prints its one column, one row per line.
param_query() {
    local query="$1" args=() p
    shift
    for p in "$@"; do args+=(--parameter="$p"); done
    bq --quiet query --project_id="$PROJECT" --location=EU --use_legacy_sql=false \
        --format=csv --max_rows=1000 "${args[@]}" <<<"$query" | tail -n +2 | sed 's/^"//;s/"$//;s/""/"/g'
}

# ranges_listed <today> <first_data_day> <last_data_day>: one line per range,
# `batch kind start end`, with a line naming any range whose request dates
# differ from its own.
ranges_listed() {
    param_query "SELECT line FROM (
  SELECT batch, n, IF(
    JSON_VALUE(d, '\$.startDate') = JSON_VALUE(r, '\$.range_start') AND JSON_VALUE(d, '\$.endDate') = JSON_VALUE(r, '\$.range_end')
      AND JSON_QUERY(request, '\$.metrics') = '[{\"name\":\"activeUsers\"},{\"name\":\"totalUsers\"},{\"name\":\"newUsers\"}]'
      AND JSON_VALUE(request, '\$.keepEmptyRows') = 'true',
    FORMAT('%d %s %s %s', batch, JSON_VALUE(r, '\$.range_kind'), JSON_VALUE(r, '\$.range_start'), JSON_VALUE(r, '\$.range_end')),
    FORMAT('%d request differs at %d', batch, n)) AS line
  FROM ($REQUESTS),
    UNNEST(JSON_QUERY_ARRAY(ranges)) AS r WITH OFFSET AS n,
    UNNEST(JSON_QUERY_ARRAY(request, '\$.dateRanges')) AS d WITH OFFSET AS m
  WHERE n = m
)
ORDER BY batch, n" "today:DATE:$1" floor:DATE:2026-10-05 "first_data_day:STRING:$2" "last_data_day:STRING:$3"
}

check requests_from_floor \
    '0 since_floor 2026-10-05 2026-10-23
0 last_7 2026-10-17 2026-10-23
0 last_28 2026-09-26 2026-10-23
0 week 2026-10-05 2026-10-11
1 week 2026-10-12 2026-10-18
1 week 2026-10-19 2026-10-23
1 month 2026-10-01 2026-10-23' \
    "$(ranges_listed 2026-10-24 20261005 20261023)"

check requests_from_first_data_day \
    '0 since_floor 2026-10-05 2026-10-23
0 last_7 2026-10-17 2026-10-23
0 last_28 2026-09-26 2026-10-23
0 week 2026-10-12 2026-10-18
1 week 2026-10-19 2026-10-23
1 month 2026-10-01 2026-10-23' \
    "$(ranges_listed 2026-10-24 20261014 20261023)"

check requests_to_last_data_day \
    '0 since_floor 2026-10-05 2026-10-25
0 last_7 2026-10-19 2026-10-25
0 last_28 2026-09-28 2026-10-25
0 week 2026-10-12 2026-10-18
1 week 2026-10-19 2026-10-25
1 month 2026-10-01 2026-10-25' \
    "$(ranges_listed 2026-10-27 20261014 20261025)"

check requests_month_after_last_data_day \
    '0 since_floor 2026-10-05 2026-10-31
0 last_7 2026-10-25 2026-10-31
0 last_28 2026-10-04 2026-10-31
0 week 2026-10-12 2026-10-18
1 week 2026-10-19 2026-10-25
1 week 2026-10-26 2026-10-31
1 month 2026-10-01 2026-10-31' \
    "$(ranges_listed 2026-11-02 20261014 20261031)"

# reply <date_range or empty> <active> <total> <new>: one Data API row.
reply() {
    local dims=""
    [ -z "$1" ] || dims="\"dimensionValues\":[{\"value\":\"$1\"}],"
    printf '{%s"metricValues":[{"value":"%s"},{"value":"%s"},{"value":"%s"}]}' "$dims" "$2" "$3" "$4"
}

# batches <first request's rows> <second request's rows>: @batches for the
# ranges of requests_from_first_data_day, the second request cut to month.
batches() {
    printf '[{"ranges":[{"range_kind":"since_floor","range_start":"2026-10-05","range_end":"2026-10-23"},{"range_kind":"last_7","range_start":"2026-10-17","range_end":"2026-10-23"},{"range_kind":"last_28","range_start":"2026-09-26","range_end":"2026-10-23"},{"range_kind":"week","range_start":"2026-10-12","range_end":"2026-10-18"}],"response":{"rows":[%s]}},' "$1"
    printf '{"ranges":[{"range_kind":"month","range_start":"2026-10-01","range_end":"2026-10-23"}],"response":{"rows":[%s]}}]' "$2"
}

# rows_written <batches>: the rows query's rows as JSON, without fetched_at,
# or its error.
rows_written() {
    param_query "SELECT TO_JSON_STRING(t) AS row FROM (SELECT * EXCEPT (fetched_at) FROM ($ROWS)) AS t
ORDER BY t.range_kind, t.range_start" "batches:STRING:$1" 2>&1 || true
}

FIRST="$(reply date_range_0 1113 1115 1061),$(reply date_range_3 891 892 847),$(reply date_range_2 1113 1115 1061),$(reply date_range_1 355 411 270)"

check rows \
    '{"range_kind":"last_28","range_start":"2026-09-26","range_end":"2026-10-23","active_users":1113,"total_users":1115,"new_users":1061}
{"range_kind":"last_7","range_start":"2026-10-17","range_end":"2026-10-23","active_users":355,"total_users":411,"new_users":270}
{"range_kind":"month","range_start":"2026-10-01","range_end":"2026-10-23","active_users":1113,"total_users":1115,"new_users":1061}
{"range_kind":"since_floor","range_start":"2026-10-05","range_end":"2026-10-23","active_users":1113,"total_users":1115,"new_users":1061}
{"range_kind":"week","range_start":"2026-10-12","range_end":"2026-10-18","active_users":891,"total_users":892,"new_users":847}' \
    "$(rows_written "$(batches "$FIRST" "$(reply '' 1113 1115 1061)")")"

check rows_zero \
    '{"range_kind":"week","range_start":"2026-10-12","range_end":"2026-10-18","active_users":0,"total_users":0,"new_users":0}' \
    "$(rows_written "$(batches "$(reply date_range_0 1113 1115 1061),$(reply date_range_3 0 0 0),$(reply date_range_2 1113 1115 1061),$(reply date_range_1 355 411 270)" "$(reply '' 1113 1115 1061)")" | grep '"week"')"

# check_refused <name> <batches>: the rows query fails with the range_rows code.
check_refused() {
    local out
    out="$(rows_written "$2")"
    if [[ "$out" == *"ga4_user_ranges:range_rows:"* ]]; then
        check "$1" refused refused
    else
        check "$1" refused "$out"
    fi
}

check_refused missing_row "$(batches "$(reply date_range_0 1113 1115 1061),$(reply date_range_3 891 892 847),$(reply date_range_1 355 411 270)" "$(reply '' 1113 1115 1061)")"
check_refused empty_reply "$(batches "$FIRST" '')"
check_refused repeated_row "$(batches "$FIRST,$(reply date_range_1 355 411 270)" "$(reply '' 1113 1115 1061)")"

finish ga4_user_ranges.test.sh
