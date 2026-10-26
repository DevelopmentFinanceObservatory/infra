#!/usr/bin/env bash
# End-to-end tests for capture-website-page-history.sh and
# website-page-history-classify.mjs against a stub `gcloud`, so nothing
# reaches Google. The stub answers each day's `gcloud logging read` with the
# synthetic entries below, written in the tab-separated shape the script asks
# gcloud for. The user agents are generic browser and crawler strings, and
# the URLs hold no ids. The script installs isbot 5.2.2 with npm, so the run
# needs npm's cache or the registry. Not wired into CI or pre-commit. Run by
# hand after touching either file:
#   scripts/capture-website-page-history.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin" "$WORK/days"

REPO="$WORK/repo"
mkdir -p "$REPO/scripts"
cp "$SCRIPT_DIR"/web-history-lib.sh "$SCRIPT_DIR"/capture-website-page-history.sh \
    "$SCRIPT_DIR"/website-page-history-classify.mjs "$REPO/scripts/"
export STUB_LOG="$WORK/calls.log" STUB_FILTERS="$WORK/filters.log" STUB_DAYS="$WORK/days"

# gcloud: logs `gcloud <day> <arguments>`, where <day> is the filter's first
# timestamp, and the filter itself on one line to $STUB_FILTERS, and prints
# $STUB_DAYS/<day>.tsv. With $STUB_FAIL_DAY set to a day, it fails on that
# day. With $STUB_WARN set, it warns on stderr and exits 0.
cat >"$WORK/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
day="$(printf '%s' "$3" | sed -n 's/.*timestamp>="\([0-9-]*\)T.*/\1/p')"
echo "gcloud $day $1 $2 ${*:4}" >>"$STUB_LOG"
printf '%s' "$3" | tr '\n' ' ' | tr -s ' ' >>"$STUB_FILTERS"
echo >>"$STUB_FILTERS"
[ "$day" != "${STUB_FAIL_DAY:-}" ] || { echo "ERROR: (gcloud.logging.read) RESOURCE_EXHAUSTED: Quota exceeded" >&2; exit 1; }
[ -z "${STUB_WARN:-}" ] || echo "WARNING: stopped early" >&2
cat "$STUB_DAYS/$day.tsv" 2>/dev/null || true
STUB
chmod +x "$WORK/bin/gcloud"
export PATH="$WORK/bin:$PATH"
[ "$(command -v gcloud)" = "$WORK/bin/gcloud" ] || { echo "gcloud stub not first on PATH" >&2; exit 1; }

browser='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'
crawler='Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)'
site='https://developmentfinance.org'

# 2026-10-14: each row names what it tests. 3 page views, 2 bot page views.
{
    printf '200\t%s/\t%s\n' "$site" "$browser"                               # page
    printf '204\thttps://www.developmentfinance.org/data\t%s\n' "$browser"   # page, www, any 2xx
    printf '200\thttps://WWW.DevelopmentFinance.org/studio\t%s\n' "$browser" # page, host case
    printf '200\t%s/data\t%s\n' "$site" "$crawler"                           # bot
    printf '200\t%s/data\t\n' "$site"                                        # bot, empty user agent
    printf '200\thttps://dfo-prod-website-abc.a.run.app/data\t%s\n' "$browser" # preview host
    printf '200\thttps://example.org/data\t%s\n' "$browser"                  # other host
    printf '404\t%s/missing\t%s\n' "$site" "$browser"                        # not 2xx
    printf '304\t%s/data\t%s\n' "$site" "$browser"                           # not 2xx
    printf '200\t%s/_next/static/chunks/main.js\t%s\n' "$site" "$browser"    # static
    printf '200\t%s/images/logo.SVG\t%s\n' "$site" "$browser"                # static, extension case
    printf '200\t%s/fonts/inter.woff2\t%s\n' "$site" "$browser"              # static
    printf '200\t%s/api/v1/data\t%s\n' "$site" "$browser"                    # api
    printf '200\t%s/api\t%s\n' "$site" "$browser"                            # api, the prefix itself
    printf '200\t%s/mcp\t%s\n' "$site" "$browser"                            # api
    printf '200\t%s/openapi.json\t%s\n' "$site" "$browser"                   # api
    printf '200\t%s/codes/indicator\t%s\n' "$site" "$browser"                # api
    printf '200\t%s/data?_rsc=1x2y3\t%s\n' "$site" "$browser"                # rsc
    printf '200\t%s/data?view=table&_rsc=1x2y3\t%s\n' "$site" "$browser"     # rsc, later parameter
    printf '200\t%s/data?view=table&_rsc\t%s\n' "$site" "$browser"           # rsc, bare, as Next.js sends an empty hash
} >"$WORK/days/2026-10-14.tsv"
# 2026-10-16: one entry, not a page view, so the day reads 0 page views.
printf '404\t%s/missing\t%s\n' "$site" "$browser" >"$WORK/days/2026-10-16.tsv"
# 2026-10-15: paths the rules must not catch. 4 page views.
{
    printf '200\t%s/apiary\t%s\n' "$site" "$browser"                         # starts with /api
    printf '200\t%s/data/_next/x\t%s\n' "$site" "$browser"                   # /_next/ below the root
    printf '200\t%s/data?from=/_next/x\t%s\n' "$site" "$browser"             # /_next/ in the query
    printf '200\t%s/data?x_rsc=1\t%s\n' "$site" "$browser"                   # not the _rsc parameter
} >"$WORK/days/2026-10-15.tsv"

failures=0
checked=0

# run <args...>: runs the capture with a fresh log, leaving its status in
# $status, its stdout in $out, its stderr in $err and the log in $calls.
run() {
    : >"$STUB_LOG"
    : >"$STUB_FILTERS"
    set +e
    out="$("$REPO/scripts/capture-website-page-history.sh" "$@" 2>"$WORK/stderr")"
    status=$?
    set -e
    err="$(cat "$WORK/stderr")"
    calls="$(cat "$STUB_LOG")"
    filters="$(cat "$STUB_FILTERS")"
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
        printf '%s\n' "$err" | sed 's/^/    err: /'
        printf '%s\n' "$calls" | sed 's/^/    log: /'
        failures=$((failures + 1))
    fi
}

is() { [ "$1" = "$2" ] && echo true || echo false; }
says() { [[ "$err" == *"$1"* ]] && echo true || echo false; }
has() { [[ "$calls" == *"$1"* ]] && echo true || echo false; }

# 1. Two days: one row each, counted by the website's rules.
run 2026-10-14 2026-10-16
check "capture exits 0" "$(is "$status" 0)"
check "capture counts each day by the page, host, status and bot rules" "$(is "$out" "$(printf '%s\n' \
    '{"date":"2026-10-14","page_views":3,"bot_page_views":2}' \
    '{"date":"2026-10-15","page_views":4,"bot_page_views":0}' \
    '{"date":"2026-10-16","page_views":0,"bot_page_views":0}')")"
check "capture reads one UTC day per call" "$(is "$(cut -d' ' -f2 <<<"$calls" | tr '\n' ' ')" "2026-10-14 2026-10-15 2026-10-16 ")"
check "capture reads the website's request log in prod" "$(has 'gcloud 2026-10-14 logging read --project=prod-fin-observatory --order=asc --format=value(httpRequest.status,httpRequest.requestUrl,httpRequest.userAgent)')"
check "capture's filter for one day holds the service, log id, status range, path and both time bounds" "$(is "$(head -n 1 <<<"$filters")" \
    'resource.type="cloud_run_revision" AND resource.labels.service_name="dfo-prod-website" AND log_id("run.googleapis.com/requests") AND httpRequest.status>=200 AND httpRequest.status<300 AND NOT httpRequest.requestUrl=~"^https?://[^/]+/_next/" AND timestamp>="2026-10-14T00:00:00Z" AND timestamp<"2026-10-15T00:00:00Z"')"
check "capture prints entries read per day" "$(says "2026-10-14: 20 entries read")"

# 2. A gcloud failure or warning fails the run and prints no rows.
STUB_FAIL_DAY=2026-10-15 run 2026-10-14 2026-10-16
check "a failed read exits 1 with no rows, naming the day and gcloud's error" \
    "$(is "$status/$out/$(says 'reading 2026-10-15 failed')/$(says RESOURCE_EXHAUSTED)" "1//true/true")"
STUB_WARN=1 run 2026-10-14 2026-10-14
check "a gcloud warning exits 1 with no rows" "$(is "$status/$out/$(says 'stopped early')" "1//true")"

# 3. A line without a status fails the run without echoing the line.
printf 'not-a-status\t%s/data\t%s\n' "$site" "$browser" >"$WORK/days/2026-10-17.tsv"
run 2026-10-17 2026-10-17
check "a line without a status exits 1 without its content" \
    "$(is "$status/$out/$(says 'line 1 has no whole-number status')/$(says "$site")" "1//true/false")"

# 4. A day with no entries fails the run and prints no rows.
run 2026-10-18 2026-10-18
check "a day with no entries exits 1 with no rows, naming the day" \
    "$(is "$status/$out/$(says '2026-10-18: no entries were read')" "1//true")"

# 5. Dates the capture refuses, before any read.
today="$(jq -rn 'now | todate[0:10]')"
for args in "2026-10-13 2026-10-15" "2026-10-15 $today" "2026-10-16 2026-10-15" "2026-10-15" "2026-10-15 2026-10-32"; do
    # shellcheck disable=SC2086 # split the case into its arguments
    run $args
    check "capture refuses [$args] with no reads" "$(is "$status/$calls" "2/")"
done

# On 2026-11-14 the _Default bucket has lost the first entries of 2026-10-15
# and keeps 2026-10-16 whole.
WEB_HISTORY_TODAY=2026-11-14 run 2026-10-15 2026-10-15
check "capture refuses a start older than 29 days with no reads, naming the retention" \
    "$(is "$status/$calls/$(says 'older than 2026-10-16')/$(says '30 days')" "2//true/true")"
WEB_HISTORY_TODAY=2026-11-14 run 2026-10-16 2026-10-16
check "capture accepts a start exactly 29 days old" "$(is "$status/$out" '0/{"date":"2026-10-16","page_views":0,"bot_page_views":0}')"

# 6. The classifier refuses any isbot other than 5.2.2.
mkdir -p "$WORK/isbot/node_modules/isbot"
echo '{"name": "isbot", "version": "5.2.1"}' >"$WORK/isbot/node_modules/isbot/package.json"
set +e
err="$(node "$REPO/scripts/website-page-history-classify.mjs" "$WORK/isbot" 2026-10-14 </dev/null 2>&1)"
status=$?
set -e
out="" calls=""
check "the classifier refuses isbot 5.2.1" "$(is "$status/$(says 'is 5.2.1')" "1/true")"

[ "$checked" -gt 0 ] || { echo "no checks ran" >&2; exit 1; }
if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed."
    exit 1
fi
echo "All $checked checks passed."
