# shellcheck shell=bash
# Shared by load-ga4-history.sh and load-search-console-history.sh, which
# source it after setting repo_root. It holds the pieces both loaders use: the
# date checks, the impersonated token, API calls, paging, and the BigQuery load
# that replaces a date range in web_history.
#
# Every call runs as the web_history_service_account output of
# infra/dfo-prod/telemetry, so the caller needs
# roles/iam.serviceAccountTokenCreator on that account and the account needs
# read access in GA4 or Search Console (that README's "Web history before the
# exports"). BigQuery is driven over its REST API with the same token, since
# bq has no impersonation flag.

# shellcheck disable=SC2154 # set by the sourcing loader
wh_telemetry_root="${repo_root:?set repo_root before sourcing web-history-lib.sh}/infra/dfo-prod/telemetry"
# Rows per API request. Search Console allows at most 25000. Tests set a small
# page to exercise paging.
wh_page_size="${WEB_HISTORY_PAGE_SIZE:-25000}"
wh_bigquery="https://bigquery.googleapis.com/bigquery/v2"

wh_require_tools() {
    local tool
    for tool in curl jq gcloud terraform; do
        command -v "$tool" >/dev/null || { echo "$tool not found." >&2; exit 1; }
    done
}

# wh_check_dates <start> <end>: exits unless both are real YYYY-MM-DD days,
# start is not after end, and end is at least 4 days before today (UTC). Both
# APIs finish a day's figures about 2 to 3 days late, and the fourth day covers
# Search Console's Pacific Time days. A run replaces its whole range, so an
# unfinished day would load as partial or empty and clear what the table held
# for it.
wh_check_dates() {
    local day latest
    for day in "$1" "$2"; do
        if ! [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
            [ "$(jq -rn --arg d "$day" '$d | strptime("%Y-%m-%d") | mktime | todate[0:10]' 2>/dev/null)" != "$day" ]; then
            echo "not a YYYY-MM-DD date: $day" >&2
            exit 2
        fi
    done
    [[ ! "$1" > "$2" ]] || { echo "start date $1 is after end date $2" >&2; exit 2; }
    latest="$(jq -rn 'now - 4 * 86400 | todate[0:10]')"
    [[ ! "$2" > "$latest" ]] || {
        echo "end date $2 is less than 4 days old, so the APIs may not have finished it; the latest end date today is $latest" >&2
        exit 2
    }
}

# wh_output <name>: prints a Terraform output of the prod telemetry stack, or
# exits if the stack has not been applied. `output -raw` on an unapplied stack
# exits 0 with a warning on stdout, so this reads -json.
wh_output() {
    local value
    value="$(cd "$wh_telemetry_root" && terraform output -json "$1" 2>/dev/null </dev/null |
        jq -r 'select(. != null)')" || true
    [ -n "$value" ] || {
        echo "Terraform output $1 not found in infra/dfo-prod/telemetry; apply the telemetry stack first." >&2
        exit 1
    }
    printf '%s\n' "$value"
}

# wh_init <api scope>: reads the service account, dataset and its location,
# mints one token for the API and BigQuery, and makes the work directory, with
# the token's header file in it.
wh_init() {
    wh_require_tools
    local dataset_ref
    wh_service_account="$(wh_output web_history_service_account)"
    dataset_ref="$(wh_output web_history_dataset)"
    wh_location="$(wh_output web_history_location)"
    wh_project="${dataset_ref%%.*}"
    wh_dataset="${dataset_ref#*.}"
    wh_token="$(gcloud auth print-access-token \
        --impersonate-service-account="$wh_service_account" \
        --scopes="$1,https://www.googleapis.com/auth/bigquery")" || {
        echo "could not mint a token as $wh_service_account" >&2
        exit 1
    }
    wh_work="$(mktemp -d)"
    trap 'rm -rf "$wh_work"' EXIT
    # curl reads the token from this file, so it stays out of the process list.
    (umask 077 && printf 'Authorization: Bearer %s\n' "$wh_token" >"$wh_work/auth")
    : >"$wh_work/create.sql"
    : >"$wh_work/tables"
}

# wh_call <method> <url> [<body file> [<content type>]]: prints the response
# body, or prints the status and body to stderr and fails on anything but 2xx.
wh_call() {
    local code args=(-sS -X "$1" -H "@$wh_work/auth" -o "$wh_work/response" -w '%{http_code}')
    [ $# -lt 3 ] || args+=(-H "Content-Type: ${4:-application/json}" --data-binary "@$3")
    code="$(curl "${args[@]}" "$2")" || { echo "request failed: $1 $2" >&2; return 1; }
    case "$code" in
    2??) cat "$wh_work/response" ;;
    *)
        echo "$1 $2 answered HTTP $code:" >&2
        cat "$wh_work/response" >&2
        echo >&2
        return 1
        ;;
    esac
}

# wh_pages <url> <request json> <offset field> <limit field>: posts the request
# a page at a time and prints every row of .rows as one JSON line. A page
# shorter than the limit is the last.
wh_pages() {
    local offset=0 page count
    while :; do
        jq --arg of "$3" --arg lf "$4" --argjson o "$offset" --argjson l "$wh_page_size" \
            '.[$of] = $o | .[$lf] = $l' <<<"$2" >"$wh_work/request"
        page="$(wh_call POST "$1" "$wh_work/request")"
        count="$(jq '.rows // [] | length' <<<"$page")"
        jq -c '.rows // [] | .[]' <<<"$page"
        [ "$count" -ge "$wh_page_size" ] || break
        offset=$((offset + count))
    done
}

# wh_wait <job json>: polls a BigQuery job until it is done, and fails with
# its errors if it failed.
wh_wait() {
    local job="$1" id location
    id="$(jq -r '.jobReference.jobId' <<<"$job")"
    location="$(jq -r '.jobReference.location' <<<"$job")"
    until [ "$(jq -r '.status.state' <<<"$job")" = DONE ]; do
        sleep 2
        job="$(wh_call GET "$wh_bigquery/projects/$wh_project/jobs/$id?location=$location")"
    done
    if jq -e '.status.errorResult' <<<"$job" >/dev/null; then
        echo "BigQuery job $id failed:" >&2
        jq '.status.errors // .status.errorResult' <<<"$job" >&2
        return 1
    fi
}

# wh_stage <table> <schema json> <rows file>: queues <table> for wh_replace,
# loading the rows into the staging table _staging_<table>, replacing it. A
# table with no rows in the range has nothing to load, so it gets no staging
# table and wh_replace only clears its range. <schema json> is a BigQuery
# fields array, and the table is created from it, partitioned by its date
# column.
wh_stage() {
    local table="$1" schema="$2" rows="$3" boundary="web_history_boundary" config job
    jq -rn --arg t "$wh_project.$wh_dataset.$table" --argjson fields "$schema" '
        "CREATE TABLE IF NOT EXISTS `\($t)` (" + ($fields | map(
            "\(.name) \(.type)\(if .mode == "REQUIRED" then " NOT NULL" else "" end) OPTIONS(description = \(.description | @json))"
        ) | join(", ")) + ") PARTITION BY date;"' >>"$wh_work/create.sql"
    if [ ! -s "$rows" ]; then
        printf '%s empty\n' "$table" >>"$wh_work/tables"
        return
    fi
    config="$(jq -nc --arg p "$wh_project" --arg l "$wh_location" --arg d "$wh_dataset" --arg t "_staging_$table" --argjson fields "$schema" '{
        jobReference: {projectId: $p, location: $l},
        configuration: {load: {
            destinationTable: {projectId: $p, datasetId: $d, tableId: $t},
            schema: {fields: $fields},
            sourceFormat: "NEWLINE_DELIMITED_JSON",
            writeDisposition: "WRITE_TRUNCATE",
            createDisposition: "CREATE_IF_NEEDED"
        }}
    }')"
    {
        printf -- '--%s\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n%s\r\n' "$boundary" "$config"
        printf -- '--%s\r\nContent-Type: application/octet-stream\r\n\r\n' "$boundary"
        cat "$rows"
        printf -- '\r\n--%s--\r\n' "$boundary"
    } >"$wh_work/upload"
    job="$(wh_call POST "https://bigquery.googleapis.com/upload/bigquery/v2/projects/$wh_project/jobs?uploadType=multipart" \
        "$wh_work/upload" "multipart/related; boundary=$boundary")"
    wh_wait "$job"
    printf '%s staged\n' "$table" >>"$wh_work/tables"
}

# wh_replace <start> <end>: runs one script that creates any missing table,
# with each CREATE as its own statement before the transaction, since DDL
# cannot run inside one. The transaction then deletes every queued table's
# rows from <start> to <end> and inserts its staged rows, if it has any.
# The staging tables are dropped after the commit. The dates are checked
# YYYY-MM-DD days, so they go into the script as literals.
wh_replace() {
    local range="date BETWEEN DATE '$1' AND DATE '$2'" ref="$wh_project.$wh_dataset" table state query job
    query="$(cat "$wh_work/create.sql")
BEGIN TRANSACTION;"
    while read -r table state; do
        query="$query
DELETE FROM \`$ref.$table\` WHERE $range;"
        [ "$state" = staged ] || continue
        query="$query
INSERT INTO \`$ref.$table\` SELECT * FROM \`$ref._staging_$table\` WHERE $range;"
    done <"$wh_work/tables"
    query="$query
COMMIT TRANSACTION;"
    while read -r table state; do
        [ "$state" = staged ] || continue
        query="$query
DROP TABLE \`$ref._staging_$table\`;"
    done <"$wh_work/tables"
    job="$(jq -n --arg p "$wh_project" --arg l "$wh_location" --arg q "$query" '{
        jobReference: {projectId: $p, location: $l},
        configuration: {query: {query: $q, useLegacySql: false}}
    }')"
    printf '%s\n' "$job" >"$wh_work/request"
    job="$(wh_call POST "$wh_bigquery/projects/$wh_project/jobs" "$wh_work/request")"
    wh_wait "$job"
}

# wh_print_days <start> <end> <label> <rows file> <label> <rows file>: prints
# the rows loaded per day into each of two tables, with 0 for a day with none.
wh_print_days() {
    jq -rn --arg s "$1" --arg e "$2" --arg la "$3" --arg lb "$5" \
        --slurpfile a "$4" --slurpfile b "$6" '
        def per_day(rows): reduce rows[] as $r ({}; .[$r.date] += 1);
        def day: strptime("%Y-%m-%d") | mktime;
        per_day($a) as $ca | per_day($b) as $cb
        | ["date", $la, $lb],
          (range($s | day; ($e | day) + 1; 86400) | todate[0:10] | [., ($ca[.] // 0), ($cb[.] // 0)])
        | @tsv'
}
