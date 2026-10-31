# shellcheck shell=bash
# Shared by the reporting_*.test.sh tests, which source it after setting DIR
# to their own directory. Each test runs a view's template from
# sql/reporting over literal source rows and compares the output with the
# rows it pins.
#
# The sources are CTEs of literal rows, so a query reads no table and scans
# no bytes. The project (default prod-fin-observatory, or the test's first
# argument) only bills and runs the jobs, and the caller needs
# bigquery.jobs.create on it.

PROJECT="${1:-prod-fin-observatory}"

# view_sql <view> <placeholder>=<text>...: prints sql/reporting/<view>.sql
# with each `${name}` placeholder, backticks included, replaced by <text>.
# Exits when a placeholder is left over.
view_sql() {
    local view="$1" sql pair name
    shift
    sql="$(cat "$DIR/../sql/reporting/$view.sql")"
    for pair in "$@"; do
        name="${pair%%=*}"
        sql="${sql//"\`\${$name}\`"/${pair#*=}}"
        sql="${sql//"\${$name}"/${pair#*=}}"
    done
    if [[ "$sql" =~ \$\{[a-z_]+\} ]]; then
        echo "$view: placeholder ${BASH_REMATCH[0]} left unreplaced" >&2
        exit 1
    fi
    printf '%s\n' "$sql"
}

# query_rows <query>: runs <query>, whose one column is a JSON row, after
# $SOURCES, a WITH clause of literal rows, and prints each row.
query_rows() {
    bq --quiet query --project_id="$PROJECT" --location=EU --use_legacy_sql=false \
        --format=csv --max_rows=1000 <<<"$SOURCES
$1" | tail -n +2 | sed 's/^"//;s/"$//;s/""/"/g'
}

# view_rows <view> <order by> <placeholder>=<text>...: prints each row of the
# view as JSON, in the given order over its columns as t.<column>.
view_rows() {
    local view="$1" order="$2" sql
    shift 2
    sql="$(view_sql "$view" "$@")" || exit 1
    query_rows "SELECT TO_JSON_STRING(t) AS row FROM (
$sql
) AS t
ORDER BY $order"
}

failures=0
cases=0

# check <name> <want> <got>: counts a case, and prints both when they differ.
check() {
    cases=$((cases + 1))
    if [ "$3" != "$2" ]; then
        echo "FAIL $1 (- want, + got):" >&2
        diff <(echo "$2") <(echo "$3") >&2 || true
        failures=$((failures + 1))
    fi
}

# finish <test name>: exits 1 when any case failed or none ran.
finish() {
    [ "$cases" -gt 0 ] || {
        echo "$1: no case ran" >&2
        exit 1
    }
    [ "$failures" -eq 0 ] || {
        echo "$1: $failures of $cases checks failed" >&2
        exit 1
    }
    echo "$1: $cases of $cases checks passed"
}
