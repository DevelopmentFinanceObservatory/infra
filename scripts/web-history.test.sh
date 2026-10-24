#!/usr/bin/env bash
# End-to-end tests for load-ga4-history.sh, load-search-console-history.sh and
# load-cloudflare-history.sh against stub `curl`, `gcloud`, `terraform` and `sleep` commands, so nothing
# reaches Google. The curl stub answers the GA4 and Search Console calls with
# the hand-written responses in testdata/web-history, written to the shape the
# APIs document, and answers every BigQuery call with a job. It keeps each
# request body and each staged upload, so the cases assert what was asked
# for and what would land in BigQuery. Not wired into CI or pre-commit. Run by
# hand after touching either loader or web-history-lib.sh:
#   scripts/web-history.test.sh
# shellcheck disable=SC2016 # backticks in expected SQL quote BigQuery table names
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$SCRIPT_DIR/testdata/web-history"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"

REPO="$WORK/repo"
mkdir -p "$REPO/scripts" "$REPO/infra/dfo-prod/telemetry"
cp "$SCRIPT_DIR"/web-history-lib.sh "$SCRIPT_DIR"/load-ga4-history.sh "$SCRIPT_DIR"/load-search-console-history.sh \
    "$SCRIPT_DIR"/load-cloudflare-history.sh "$REPO/scripts/"
export STUB_LOG="$WORK/calls.log" STUB_STATE="$WORK/state" STUB_FIXTURES="$FIXTURES"
export WEB_HISTORY_PAGE_SIZE=2

# curl: logs `curl <method> <url>`, keeps its arguments in $STUB_STATE/argv
# and the contents of any `-H @file` in $STUB_STATE/headers. A GA4 runReport or
# Search Console query answers with testdata/web-history/<api>-<dimensions>-<offset>.json, and its
# body is kept as $STUB_STATE/requests/<n>.json in call order. A BigQuery
# upload keeps its rows as $STUB_STATE/staged/<table>.json and answers with a
# running job; a job GET answers done. A BigQuery job insert keeps its query
# as $STUB_STATE/query.sql and answers done, or failed when
# $STUB_QUERY_FAILS is set. A URL containing $STUB_HTTP_ERROR answers 403. A
# report whose dimensions, joined by _, are listed in $STUB_EMPTY answers with
# the recorded empty page instead, and with $STUB_VARIANT set, a report whose
# fixture has a <name>-$STUB_VARIANT.json variant answers with that.
cat >"$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
method="" out="" body="" url=""
echo "$*" >>"$STUB_STATE/argv"
while [ $# -gt 0 ]; do
    case "$1" in
    -X) method="$2"; shift ;;
    -o) out="$2"; shift ;;
    --data-binary) body="${2#@}"; shift ;;
    -H)
        case "$2" in @*) cat "${2#@}" >>"$STUB_STATE/headers" ;; esac
        shift
        ;;
    -w) shift ;;
    -*) ;;
    *) url="$1" ;;
    esac
    shift
done
echo "curl $method $url" >>"$STUB_LOG"
answer() { printf '%s\n' "$2" >"$out"; printf '%s' "$1"; }
if [ -n "${STUB_HTTP_ERROR:-}" ] && [[ "$url" == *"$STUB_HTTP_ERROR"* ]]; then
    answer 403 '{"error": {"code": 403, "message": "User does not have sufficient permissions", "status": "PERMISSION_DENIED"}}'
    exit 0
fi
case "$url" in
*:runReport | */searchAnalytics/query)
    mkdir -p "$STUB_STATE/requests"
    n="$(find "$STUB_STATE/requests" -type f | wc -l | tr -d ' ')"
    cp "$body" "$STUB_STATE/requests/$n.json"
    case "$url" in *:runReport) api=ga4 ;; *) api=gsc ;; esac
    key="$(jq -r '[(.dimensions | map(.name? // .) | join("_")), (.offset // .startRow)] | join("-")' "$body")"
    fixture="$STUB_FIXTURES/$api-$key.json"
    [ ! -f "$STUB_FIXTURES/$api-$key-${STUB_VARIANT:-}.json" ] || fixture="$STUB_FIXTURES/$api-$key-$STUB_VARIANT.json"
    case " ${STUB_EMPTY:-} " in
    *" ${key%-*} "*) case "$api" in ga4) fixture="$STUB_FIXTURES/ga4-date_pagePath-4.json" ;; *) fixture="$STUB_FIXTURES/gsc-date-2.json" ;; esac ;;
    esac
    if [ -f "$fixture" ]; then answer 200 "$(cat "$fixture")"; else answer 500 "{\"error\": \"stub has no $api-$key.json\"}"; fi
    ;;
*/upload/bigquery/*)
    mkdir -p "$STUB_STATE/staged"
    tr -d '\r' <"$body" >"$STUB_STATE/upload"
    table="$(awk 'NR == 4' "$STUB_STATE/upload" | jq -r '.configuration.load.destinationTable.tableId')"
    awk '/^Content-Type: application\/octet-stream/ { rows = 1; getline; next } /^--web_history_boundary--/ { rows = 0 } rows' \
        "$STUB_STATE/upload" >"$STUB_STATE/staged/$table.json"
    answer 200 "{\"jobReference\": {\"jobId\": \"load-$table\", \"location\": \"$(awk 'NR == 4' "$STUB_STATE/upload" | jq -r '.jobReference.location')\"}, \"status\": {\"state\": \"RUNNING\"}}"
    ;;
*/jobs/*)
    answer 200 '{"jobReference": {"jobId": "polled", "location": "EU"}, "status": {"state": "DONE"}}'
    ;;
*/jobs)
    cp "$body" "$STUB_STATE/query-job.json"
    jq -r '.configuration.query.query' "$body" >"$STUB_STATE/query.sql"
    if [ -n "${STUB_QUERY_FAILS:-}" ]; then
        answer 200 '{"jobReference": {"jobId": "query", "location": "EU"}, "status": {"state": "DONE", "errorResult": {"reason": "invalidQuery", "message": "Syntax error"}, "errors": [{"reason": "invalidQuery", "message": "Syntax error"}]}}'
    else
        answer 200 '{"jobReference": {"jobId": "query", "location": "EU"}, "status": {"state": "DONE"}}'
    fi
    ;;
*) answer 404 "{\"error\": \"stub has no route for $url\"}" ;;
esac
STUB
# gcloud: logs its arguments and prints a token.
cat >"$WORK/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >>"$STUB_LOG"
echo stub-token
STUB
# terraform: `output -json NAME` prints the three web_history outputs as an
# applied prod telemetry stack would, naming the root it ran in. With
# $STUB_UNAPPLIED set, every output is missing.
cat >"$WORK/bin/terraform" <<'STUB'
#!/usr/bin/env bash
echo "terraform ${PWD#*/repo/} $*" >>"$STUB_LOG"
[ -z "${STUB_UNAPPLIED:-}" ] || { printf 'Error: Output "%s" not found\n' "$3" >&2; exit 1; }
case "$3" in
web_history_service_account) echo '"web-history@test-project.iam.gserviceaccount.com"' ;;
web_history_dataset) echo '"test-project.web_history"' ;;
web_history_location) echo '"test-location"' ;;
*) printf 'Error: Output "%s" not found\n' "$3" >&2; exit 1 ;;
esac
STUB
cat >"$WORK/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo "sleep $*" >>"$STUB_LOG"
STUB
chmod +x "$WORK/bin/curl" "$WORK/bin/gcloud" "$WORK/bin/terraform" "$WORK/bin/sleep"
export PATH="$WORK/bin:$PATH"

for tool in curl gcloud terraform sleep; do
    [ "$(command -v "$tool")" = "$WORK/bin/$tool" ] || { echo "$tool stub not first on PATH" >&2; exit 1; }
done

failures=0
checked=0

# run <script> <args...>: runs a loader with a fresh log and state, leaving
# its status in $status, its output in $out and the log in $calls.
run() {
    local script="$1"
    shift
    : >"$STUB_LOG"
    rm -rf "$STUB_STATE"
    mkdir "$STUB_STATE"
    set +e
    out="$("$REPO/scripts/$script" "$@" 2>&1)"
    status=$?
    set -e
    calls="$(cat "$STUB_LOG")"
}

# check <label> <true|false>: records a pass or failure, showing the last
# run's output and calls on failure.
check() {
    local label="$1" ok="$2"
    checked=$((checked + 1))
    if [ "$ok" = true ]; then
        echo "ok: $label"
    else
        echo "FAIL: $label"
        printf '%s\n' "$out" | sed 's/^/    out: /'
        printf '%s\n' "$calls" | sed 's/^/    log: /'
        failures=$((failures + 1))
    fi
}

says() { [[ "$out" == *"$1"* ]] && echo true || echo false; }
has() { [[ "$calls" == *"$1"* ]] && echo true || echo false; }
lacks() { [[ "$calls" != *"$1"* ]] && echo true || echo false; }
is() { [ "$1" = "$2" ] && echo true || echo false; }
# staged <table>: the rows the last run uploaded for <table>, sorted.
staged() { jq -cS . "$STUB_STATE/staged/_staging_$1.json" | LC_ALL=C sort; }
# request <n> <jq>: a field of the last run's nth API request.
request() { jq -c "$2" "$STUB_STATE/requests/$1.json"; }
query_has() { grep -qF -- "$1" "$STUB_STATE/query.sql" && echo true || echo false; }

# 1. GA4: pages are paged by offset until a short page, page rows are staged
# as returned, and the day totals come from their own report.
run load-ga4-history.sh 123456789 2026-10-05 2026-10-07
check "ga4 load exits 0" "$(is "$status" 0)"
check "ga4 reads the outputs from the prod telemetry root" "$(has "terraform infra/dfo-prod/telemetry output -json web_history_service_account")"
check "ga4 impersonates the service account with both scopes" "$(has "gcloud auth print-access-token --impersonate-service-account=web-history@test-project.iam.gserviceaccount.com --scopes=https://www.googleapis.com/auth/analytics.readonly,https://www.googleapis.com/auth/bigquery")"
check "ga4 posts to the property's runReport" "$(has "curl POST https://analyticsdata.googleapis.com/v1beta/properties/123456789:runReport")"
check "ga4 pages by offset 0, 2, 4" "$(is "$(for n in 0 1 2; do request "$n" '[.offset, .limit]'; done | tr -d '\n')" "[0,2][2,2][4,2]")"
check "ga4 asks for date and pagePath with the three metrics" "$(is "$(request 0 '[.dimensions, .metrics, .dateRanges]')" '[[{"name":"date"},{"name":"pagePath"}],[{"name":"activeUsers"},{"name":"sessions"},{"name":"screenPageViews"}],[{"startDate":"2026-10-05","endDate":"2026-10-07"}]]')"
check "ga4 asks for date alone for the totals" "$(is "$(request 3 '.dimensions')" '[{"name":"date"}]')"
check "ga4 stages page rows as returned" "$(is "$(staged ga4_pages_daily)" "$(printf '%s\n' \
    '{"active_users":25,"date":"2026-10-06","page_path":"/","screen_page_views":61,"sessions":30}' \
    '{"active_users":3,"date":"2026-10-05","page_path":"/data/kenya","screen_page_views":4,"sessions":3}' \
    '{"active_users":40,"date":"2026-10-05","page_path":"/","screen_page_views":90,"sessions":52}' \
    '{"active_users":7,"date":"2026-10-05","page_path":"/data","screen_page_views":11,"sessions":8}')")"
check "ga4 passes the token in a header file" "$(is "$(sort -u "$STUB_STATE/headers")" "Authorization: Bearer stub-token")"
check "ga4 keeps the token out of curl's arguments" "$(is "$(grep -c stub-token "$STUB_STATE/argv")" 0)"
check "ga4 stages day totals" "$(is "$(staged ga4_daily)" "$(printf '%s\n' \
    '{"active_users":25,"date":"2026-10-06","screen_page_views":61,"sessions":30}' \
    '{"active_users":45,"date":"2026-10-05","screen_page_views":105,"sessions":63}')")"
check "ga4 waits on a running load job" "$(has "curl GET https://bigquery.googleapis.com/bigquery/v2/projects/test-project/jobs/load-_staging_ga4_daily?location=test-location")"
check "ga4 runs the query job in the dataset's location" "$(is "$(jq -r '.jobReference.location' "$STUB_STATE/query-job.json")" test-location)"
check "ga4 creates the page table with its schema, partitioned by day" "$(query_has 'CREATE TABLE IF NOT EXISTS `test-project.web_history.ga4_pages_daily` (date DATE NOT NULL OPTIONS(description = "Day in the GA4 property'"'"'s reporting time zone."), page_path STRING NOT NULL')"
check "ga4 partitions the totals table by day" "$(query_has "screen_page_views INT64 NOT NULL OPTIONS(description = \"GA4 screenPageViews.\")) PARTITION BY date;")"
check "ga4 deletes the range from the page table" "$(query_has "DELETE FROM \`test-project.web_history.ga4_pages_daily\` WHERE date BETWEEN DATE '2026-10-05' AND DATE '2026-10-07';")"
check "ga4 inserts the staged totals" "$(query_has "INSERT INTO \`test-project.web_history.ga4_daily\` SELECT * FROM \`test-project.web_history._staging_ga4_daily\` WHERE date BETWEEN DATE '2026-10-05' AND DATE '2026-10-07';")"
check "ga4 replaces inside one transaction and drops staging after" "$(is "$(grep -E '^(BEGIN|DELETE|COMMIT|DROP)' "$STUB_STATE/query.sql" | cut -d' ' -f1 | tr '\n' ' ')" "BEGIN DELETE DELETE COMMIT DROP DROP ")"
check "ga4 prints rows per day, with 0 for an empty day" "$(says "$(printf 'date\tga4_pages_daily\tga4_daily\n2026-10-05\t3\t1\n2026-10-06\t1\t1\n2026-10-07\t0\t0')")"

# 2. Search Console: paged by startRow, final web data by date and page and
# by date alone, with no query dimension, query strings and fragments stripped
# and their rows summed, and position on the bulk export's scale (top is 0)
# weighted by impressions.
run load-search-console-history.sh sc-domain:developmentfinance.org 2026-10-05 2026-10-07
check "search console load exits 0" "$(is "$status" 0)"
check "search console impersonates with the webmasters scope" "$(has "--scopes=https://www.googleapis.com/auth/webmasters.readonly,https://www.googleapis.com/auth/bigquery")"
check "search console encodes the site in the URL" "$(has "curl POST https://searchconsole.googleapis.com/webmasters/v3/sites/sc-domain%3Adevelopmentfinance.org/searchAnalytics/query")"
check "search console pages by startRow 0, 2" "$(is "$(for n in 0 1; do request "$n" '[.startRow, .rowLimit]'; done | tr -d '\n')" "[0,2][2,2]")"
check "search console asks for final web data by date and page" "$(is "$(request 0 '[.dimensions, .type, .dataState, .startDate, .endDate]')" '[["date","page"],"web","final","2026-10-05","2026-10-07"]')"
check "search console asks for date alone for the totals" "$(is "$(request 2 '.dimensions')" '["date"]')"
check "search console never asks for the query dimension" "$(is "$(jq -s 'map(.dimensions[]) | index("query")' "$STUB_STATE"/requests/*.json)" null)"
check "search console stages page rows with URLs cleaned and summed" "$(is "$(staged search_console_pages_daily)" "$(printf '%s\n' \
    '{"clicks":1,"date":"2026-10-05","impressions":40,"sum_position":520,"url":"https://developmentfinance.org/data"}' \
    '{"clicks":4,"date":"2026-10-05","impressions":120,"sum_position":900,"url":"https://developmentfinance.org/"}')")"
check "search console stages day totals" "$(is "$(staged search_console_daily)" "$(printf '%s\n' \
    '{"clicks":0,"date":"2026-10-07","impressions":6,"sum_position":180}' \
    '{"clicks":5,"date":"2026-10-05","impressions":140,"sum_position":1155}')")"
check "search console deletes the range from the page table" "$(query_has "DELETE FROM \`test-project.web_history.search_console_pages_daily\` WHERE date BETWEEN DATE '2026-10-05' AND DATE '2026-10-07';")"
check "search console deletes the range from the totals table" "$(query_has "DELETE FROM \`test-project.web_history.search_console_daily\` WHERE date BETWEEN DATE '2026-10-05' AND DATE '2026-10-07';")"
check "search console prints rows per day" "$(says "$(printf 'date\tsearch_console_pages_daily\tsearch_console_daily\n2026-10-05\t2\t1\n2026-10-06\t0\t0\n2026-10-07\t0\t1')")"

# 3. A table with no rows in the range uploads nothing and still has its
# range deleted, so a rerun clears stale rows. Its CREATE still runs, before
# the transaction.
STUB_EMPTY=date_pagePath run load-ga4-history.sh 123456789 2026-10-05 2026-10-07
check "one empty table exits 0" "$(is "$status" 0)"
check "one empty table uploads only the other" "$(is "$(ls "$STUB_STATE/staged")" _staging_ga4_daily.json)"
check "one empty table creates both tables before the transaction" "$(is "$(grep -E '^(CREATE|BEGIN)' "$STUB_STATE/query.sql" | cut -d' ' -f1-7 | tr '\n' '|')" 'CREATE TABLE IF NOT EXISTS `test-project.web_history.ga4_pages_daily` (date|CREATE TABLE IF NOT EXISTS `test-project.web_history.ga4_daily` (date|BEGIN TRANSACTION;|')"
check "one empty table deletes both ranges and inserts and drops only the staged one" "$(is "$(grep -E '^(DELETE|INSERT|DROP)' "$STUB_STATE/query.sql" | cut -d' ' -f1-3 | tr '\n' '|')" 'DELETE FROM `test-project.web_history.ga4_pages_daily`|DELETE FROM `test-project.web_history.ga4_daily`|INSERT INTO `test-project.web_history.ga4_daily`|DROP TABLE `test-project.web_history._staging_ga4_daily`;|')"
check "one empty table prints 0 for it" "$(says "$(printf '2026-10-05\t0\t1\n2026-10-06\t0\t1')")"

STUB_EMPTY="date_page date" run load-search-console-history.sh sc-domain:developmentfinance.org 2026-10-05 2026-10-07
check "empty range exits 0" "$(is "$status" 0)"
check "empty range uploads nothing" "$(lacks "upload/bigquery")"
check "empty range deletes both ranges in one transaction, with no insert or drop" "$(is "$(grep -E '^(BEGIN|DELETE|INSERT|COMMIT|DROP)' "$STUB_STATE/query.sql" | cut -d' ' -f1 | tr '\n' ' ')" "BEGIN DELETE DELETE COMMIT ")"
check "empty range deletes the range from the page table" "$(query_has "DELETE FROM \`test-project.web_history.search_console_pages_daily\` WHERE date BETWEEN DATE '2026-10-05' AND DATE '2026-10-07';")"
check "empty range prints 0 for every day" "$(says "$(printf '2026-10-05\t0\t0\n2026-10-06\t0\t0\n2026-10-07\t0\t0')")"

# 4. GA4 rows repeating a day and page path stop the run before BigQuery, since
# users and sessions do not sum across rows.
STUB_VARIANT=duplicate run load-ga4-history.sh 123456789 2026-10-05 2026-10-07
check "ga4 duplicate exits 1" "$(is "$status" 1)"
check "ga4 duplicate names the day and path" "$(says "$(printf 'more than one row for these days and page paths:\n2026-10-05 /data')")"
check "ga4 duplicate loads nothing" "$(lacks "bigquery.googleapis.com")"

# 5. An end date less than 4 days old (UTC) is refused, and one exactly 4
# days old loads.
latest="$(jq -rn 'now - 4 * 86400 | todate[0:10]')"
too_late="$(jq -rn 'now - 3 * 86400 | todate[0:10]')"
run load-search-console-history.sh sc-domain:developmentfinance.org 2026-10-05 "$too_late"
check "search console refuses an end date 3 days old with no calls" "$(is "$status/$calls" "2/")"
check "the refusal names the latest end date" "$(says "the latest end date today is $latest")"
run load-ga4-history.sh 123456789 2026-10-05 "$too_late"
check "ga4 refuses an end date 3 days old with no calls" "$(is "$status/$calls" "2/")"
run load-ga4-history.sh 123456789 2026-10-05 "$latest"
check "ga4 loads an end date 4 days old" "$(is "$status" 0)"

# 6. Bad arguments are refused before any Terraform, gcloud or API call.
for args in "" "123456789 2026-10-05" "12345abc 2026-10-05 2026-10-07" "123456789 2026-02-30 2026-03-01" "123456789 2026-10-07 2026-10-05" "123456789 05/10/2026 2026-10-07"; do
    # shellcheck disable=SC2086 # split the case into its arguments
    run load-ga4-history.sh $args
    check "ga4 refuses [$args] with no calls" "$(is "$status/$calls" "2/")"
done
for args in "sc-domain:developmentfinance.org 2026-10-05" "https://developmentfinance.org 2026-10-05 2026-10-07" "developmentfinance.org 2026-10-05 2026-10-07"; do
    # shellcheck disable=SC2086 # split the case into its arguments
    run load-search-console-history.sh $args
    check "search console refuses [$args] with no calls" "$(is "$status/$calls" "2/")"
done

# 7. An unapplied stack stops the run before a token is minted.
STUB_UNAPPLIED=1 run load-ga4-history.sh 123456789 2026-10-05 2026-10-07
check "unapplied stack exits 1" "$(is "$status" 1)"
check "unapplied stack names the output" "$(says "Terraform output web_history_service_account not found")"
check "unapplied stack mints no token" "$(lacks "gcloud")"

# 8. An API error stops the run with its status and body, before BigQuery.
STUB_HTTP_ERROR=searchAnalytics run load-search-console-history.sh https://developmentfinance.org/ 2026-10-05 2026-10-07
check "api error exits non-zero" "$(is "$status" 1)"
check "api error prints the status" "$(says "answered HTTP 403:")"
check "api error prints the body" "$(says "User does not have sufficient permissions")"
check "api error loads nothing" "$(lacks "bigquery.googleapis.com")"

# 9. A failed BigQuery job stops the run with its errors, and prints no days.
STUB_QUERY_FAILS=1 run load-ga4-history.sh 123456789 2026-10-05 2026-10-07
check "failed job exits non-zero" "$(is "$status" 1)"
check "failed job prints its errors" "$(says "Syntax error")"
check "failed job prints no rows per day" "$(is "$(says "Rows per day")" false)"

# 10. Cloudflare: the file's rows are staged sorted and cut to the table's
# three fields, with a BigQuery-only token. Cloudflare's figures are final once
# the UTC day ends, so an end date of yesterday loads and one of today is
# refused.
run load-cloudflare-history.sh "$FIXTURES/cloudflare.jsonl" 2026-10-05 2026-10-07
check "cloudflare load exits 0" "$(is "$status" 0)"
check "cloudflare impersonates with the BigQuery scope alone" "$(has "--impersonate-service-account=web-history@test-project.iam.gserviceaccount.com --scopes=https://www.googleapis.com/auth/bigquery")"
check "cloudflare stages the rows cut to the table's fields" "$(is "$(staged cloudflare_daily)" "$(printf '%s\n' \
    '{"date":"2026-10-05","page_loads":483,"verified_bot_page_loads":6}' \
    '{"date":"2026-10-07","page_loads":213,"verified_bot_page_loads":5}')")"
check "cloudflare creates the table with its schema, partitioned by day" "$(query_has 'CREATE TABLE IF NOT EXISTS `test-project.web_history.cloudflare_daily` (date DATE NOT NULL OPTIONS(description = "UTC day, as Cloudflare reports it."), page_loads INT64 NOT NULL')"
check "cloudflare replaces the range in one transaction" "$(is "$(grep -E '^(BEGIN|DELETE|INSERT|COMMIT|DROP)' "$STUB_STATE/query.sql" | cut -d' ' -f1-3 | tr '\n' '|')" 'BEGIN TRANSACTION;|DELETE FROM `test-project.web_history.cloudflare_daily`|INSERT INTO `test-project.web_history.cloudflare_daily`|COMMIT TRANSACTION;|DROP TABLE `test-project.web_history._staging_cloudflare_daily`;|')"
check "cloudflare deletes the whole range" "$(query_has "DELETE FROM \`test-project.web_history.cloudflare_daily\` WHERE date BETWEEN DATE '2026-10-05' AND DATE '2026-10-07';")"
check "cloudflare prints the rows it loaded" "$(says "$(printf 'date\tpage_loads\tverified_bot_page_loads\n2026-10-05\t483\t6\n2026-10-07\t213\t5')")"
yesterday="$(jq -rn 'now - 86400 | todate[0:10]')"
today="$(jq -rn 'now | todate[0:10]')"
printf '{"date":"%s","page_loads":1,"verified_bot_page_loads":0}\n' "$yesterday" >"$WORK/yesterday.jsonl"
run load-cloudflare-history.sh "$WORK/yesterday.jsonl" "$yesterday" "$yesterday"
check "cloudflare loads an end date of yesterday" "$(is "$status" 0)"
printf '{"date":"%s","page_loads":1,"verified_bot_page_loads":0}\n' "$today" >"$WORK/today.jsonl"
run load-cloudflare-history.sh "$WORK/today.jsonl" "$today" "$today"
check "cloudflare refuses an end date of today with no calls" "$(is "$status/$calls" "2/")"
check "the refusal names yesterday as the latest end date" "$(says "the latest end date today is $yesterday")"

# 11. A file that cannot load as given is refused before any Terraform,
# gcloud or BigQuery call, naming what is wrong.
bad_file() { printf '%s\n' "$@" >"$WORK/bad.jsonl"; }
day5='{"date":"2026-10-05","page_loads":1,"verified_bot_page_loads":0}'
bad_file "$day5" '{"date":"2026-10-08","page_loads":1,"verified_bot_page_loads":0}'
run load-cloudflare-history.sh "$WORK/bad.jsonl" 2026-10-05 2026-10-07
check "cloudflare refuses a date outside the range with no calls" "$(is "$status/$calls" "2/")"
check "the refusal names the date outside the range" "$(says "$(printf 'dates outside 2026-10-05 to 2026-10-07:\n2026-10-08')")"
bad_file "$day5" "$day5"
run load-cloudflare-history.sh "$WORK/bad.jsonl" 2026-10-05 2026-10-07
check "cloudflare refuses a repeated date with no calls" "$(is "$status/$calls" "2/")"
check "the refusal names the repeated date" "$(says "$(printf 'dates on more than one row:\n2026-10-05')")"
for row in '{"date":"2026-10-05","page_loads":1}' '{"date":"2026-10-05","page_loads":-1,"verified_bot_page_loads":0}' \
    '{"date":"2026-10-05","page_loads":1.5,"verified_bot_page_loads":0}' '{"date":"2026-02-30","page_loads":1,"verified_bot_page_loads":0}' \
    '{"date":"20261005","page_loads":1,"verified_bot_page_loads":0}' '[1]'; do
    bad_file "$row"
    run load-cloudflare-history.sh "$WORK/bad.jsonl" 2026-01-01 2026-12-31
    check "cloudflare refuses the row $row with no calls" "$(is "$status/$calls" "2/")"
done
: >"$WORK/bad.jsonl"
run load-cloudflare-history.sh "$WORK/bad.jsonl" 2026-10-05 2026-10-07
check "cloudflare refuses an empty file with no calls" "$(is "$status/$calls" "2/")"
bad_file '{"date":'
run load-cloudflare-history.sh "$WORK/bad.jsonl" 2026-10-05 2026-10-07
check "cloudflare refuses a file that is not JSON with no calls" "$(is "$status/$calls" "2/")"
for args in "$FIXTURES/cloudflare.jsonl 2026-10-05" "$WORK/missing.jsonl 2026-10-05 2026-10-07" "$FIXTURES/cloudflare.jsonl 2026-10-07 2026-10-05"; do
    # shellcheck disable=SC2086 # split the case into its arguments
    run load-cloudflare-history.sh $args
    check "cloudflare refuses [${args#"$WORK"/}] with no calls" "$(is "$status/$calls" "2/")"
done

[ "$checked" -gt 0 ] || { echo "no checks ran" >&2; exit 1; }
if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed."
    exit 1
fi
echo "All $checked checks passed."
