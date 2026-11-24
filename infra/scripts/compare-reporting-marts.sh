#!/usr/bin/env bash
# Compares each dfo_reporting view in reporting_mart_views
# (infra/stacks/telemetry/reporting_views.tf) with the table of the same name
# the analytics dbt build writes in reporting_marts. Run it before each step
# of reporting_marts_cutover (infra/dfo-prod/telemetry/README.md, "Reporting
# marts cutover"):
#   infra/scripts/compare-reporting-marts.sh [mart dataset] [project]
#
# For each view it prints counts only, no rows:
# - whether the column names, order and types match on both sides;
# - the first and last day each side holds;
# - on the days both hold before the current UTC day, the rows on each side
#   and the rows found on one side alone, counted as a multiset so a
#   duplicated row counts. Floats are rounded and sketches compared by their
#   estimates, since a sum's last digits depend on the order BigQuery adds in.
# Exits 1 when any view differs. The view reads its sources live and the
# table holds them as of the last hourly build at :25, so a difference on the
# newest day alone can be a row that arrived since; rerun after the next build.
set -euo pipefail

DATASET="${1:-reporting_marts}"
PROJECT="${2:-prod-fin-observatory}"

# projection <view>: prints the view's day column, a tab, and the columns
# compared, with floats rounded and sketches replaced by their estimates.
projection() {
    case "$1" in
    ga4_daily) printf 'day\tday, active_users, sessions, page_views, declined_page_views, HLL_COUNT.EXTRACT(users_sketch) AS users' ;;
    ga4_pages_daily) printf 'day\tday, page_path, page_views, sessions, declined_page_views' ;;
    ga4_user_ranges) printf 'range_end\trange_kind, range_start, range_end, active_users, total_users, new_users, fetched_at' ;;
    search_console_daily) printf 'day\tday, clicks, impressions, ROUND(sum_position, 6) AS sum_position' ;;
    search_console_pages) printf 'day\tday, url, clicks, impressions, ROUND(sum_position, 6) AS sum_position' ;;
    ai_turns) printf 'day\tday, started_at, HLL_COUNT.EXTRACT(session_sketch) AS sessions, ROUND(latency_seconds, 6) AS latency_seconds, ROUND(time_to_first_token_seconds, 6) AS ttft, generations, tool_calls, input_tokens, output_tokens, ROUND(cost_usd, 6) AS cost_usd, errored, cached_input_tokens' ;;
    ai_observations_daily) printf 'day\tday, type, name, model, observations, errors, ROUND(latency_p50_seconds, 3) AS p50, ROUND(latency_p95_seconds, 3) AS p95, input_tokens, output_tokens, ROUND(cost_usd, 6) AS cost_usd, trace_name, level, total_tokens, ROUND(KLL_QUANTILES.EXTRACT_POINT_FLOAT64(latency_sketch, 0.5), 3) AS sketch_p50, cached_input_tokens' ;;
    model_spend_daily) printf 'day\tday, caller, service, sku, ROUND(cost, 6) AS cost, ROUND(credits, 6) AS credits, ROUND(net_cost, 6) AS net_cost, currency' ;;
    accounts_daily) printf 'day\tday, organisation, accounts' ;;
    account_returns_daily) printf 'day\tday, HLL_COUNT.EXTRACT(active_sketch) AS active, HLL_COUNT.EXTRACT(returning_sketch) AS returning' ;;
    product_events_daily) printf 'day\tday, event, page, signed_in, events, HLL_COUNT.EXTRACT(visitors_sketch) AS visitors, HLL_COUNT.EXTRACT(users_sketch) AS users' ;;
    cloudflare_daily) printf 'day\tday, page_loads, verified_bot_page_loads' ;;
    cloudflare_pages_daily) printf 'day\tday, path, page_loads, verified_bot_page_loads' ;;
    *)
        echo "no projection for $1" >&2
        exit 2
        ;;
    esac
}

VIEWS="account_returns_daily accounts_daily ai_observations_daily ai_turns cloudflare_daily cloudflare_pages_daily ga4_daily ga4_pages_daily ga4_user_ranges model_spend_daily product_events_daily search_console_daily search_console_pages"

# query <sql>: runs <sql> and prints its one result row as CSV.
query() {
    bq --quiet query --project_id="$PROJECT" --location=EU --use_legacy_sql=false \
        --format=csv --max_rows=1 <<<"$1" | tail -n +2
}

# columns <dataset> <table>: prints the table's columns in order with types.
columns() {
    query "SELECT STRING_AGG(column_name || ' ' || data_type, ', ' ORDER BY ordinal_position)
FROM \`$PROJECT.$1.INFORMATION_SCHEMA.COLUMNS\` WHERE table_name = '$2'"
}

differ=0
covered=0
for view in $VIEWS; do
    covered=$((covered + 1))
    spec="$(projection "$view")"
    day="${spec%%$'\t'*}"
    proj="${spec#*$'\t'}"
    v="\`$PROJECT.dfo_reporting.$view\`"
    m="\`$PROJECT.$DATASET.$view\`"

    if [ "$(columns dfo_reporting "$view")" = "$(columns "$DATASET" "$view")" ]; then
        cols=same
    else
        cols=DIFFER
    fi

    # Prints view_first,view_last,mart_first,mart_last,view_rows,mart_rows,
    # view_only,mart_only.
    counts="$(query "WITH
  bounds AS (
    SELECT (SELECT MIN($day) FROM $v) AS view_first, (SELECT MAX($day) FROM $v) AS view_last,
           (SELECT MIN($day) FROM $m) AS mart_first, (SELECT MAX($day) FROM $m) AS mart_last
  ),
  overlap AS (
    SELECT GREATEST(view_first, mart_first) AS lo,
           LEAST(view_last, mart_last, CURRENT_DATE() - 1) AS hi
    FROM bounds
  ),
  sides AS (
    SELECT 'view' AS side, TO_JSON_STRING(t) AS k FROM (SELECT $proj FROM $v) AS t, overlap WHERE t.$day BETWEEN lo AND hi
    UNION ALL
    SELECT 'mart' AS side, TO_JSON_STRING(t) AS k FROM (SELECT $proj FROM $m) AS t, overlap WHERE t.$day BETWEEN lo AND hi
  ),
  keyed AS (
    SELECT k, COUNTIF(side = 'view') AS nv, COUNTIF(side = 'mart') AS nm FROM sides GROUP BY k
  )
SELECT b.view_first, b.view_last, b.mart_first, b.mart_last,
  IFNULL(SUM(nv), 0), IFNULL(SUM(nm), 0),
  IFNULL(SUM(GREATEST(nv - nm, 0)), 0), IFNULL(SUM(GREATEST(nm - nv, 0)), 0)
FROM bounds AS b LEFT JOIN keyed ON TRUE
GROUP BY 1, 2, 3, 4")"
    IFS=, read -r view_first view_last mart_first mart_last view_rows mart_rows view_only mart_only <<<"$counts"

    status=same
    if [ "$cols" != same ] || [ "$view_only" != 0 ] || [ "$mart_only" != 0 ] || [ "$view_rows" = 0 ]; then
        status=DIFFER
        differ=$((differ + 1))
    fi
    printf '%s %s columns=%s view=%s..%s mart=%s..%s rows=%s/%s view_only=%s mart_only=%s\n' \
        "$status" "$view" "$cols" "$view_first" "$view_last" "$mart_first" "$mart_last" \
        "$view_rows" "$mart_rows" "$view_only" "$mart_only"
done

[ "$covered" -gt 0 ] || {
    echo "no view compared" >&2
    exit 1
}
echo "$((covered - differ)) of $covered views match $DATASET"
[ "$differ" -eq 0 ]
