# shellcheck shell=bash
# Shared by load_from.test.sh, mcp_daily.test.sh and
# website_requests_daily.test.sh, which source it after setting DIR to their
# own directory. script_rows also needs PROJECT, and the SCRIPT it runs.

# statements <pattern>: the statements of logs_daily.sql that start with
# <pattern>, each ending at a line that ends in ";", with comment lines
# dropped. Exits when none matches.
statements() {
    local found
    found="$(awk -v pattern="^($1)" '
        { buf = buf $0 "\n" }
        /;[[:space:]]*$/ {
            body = buf
            gsub(/(^|\n)[[:space:]]*--[^\n]*/, "", body)
            sub(/^[[:space:]]+/, "", body)
            if (body ~ pattern) printf "%s\n", body
            buf = ""
        }
    ' "$DIR/../sql/logs_daily.sql")"
    [ -n "$found" ] || {
        echo "${BASH_SOURCE[1]##*/}: no statement in logs_daily.sql starts with $1" >&2
        exit 1
    }
    printf '%s\n' "$found"
}

# script_rows <query>: runs $SCRIPT and then <query>, whose one column is a
# JSON row named row, and prints each row. bq prints each statement of a
# script and its result, so the rows are those after the last header.
script_rows() {
    bq --quiet query --project_id="$PROJECT" --location=EU --use_legacy_sql=false \
        --format=csv --max_rows=1000 <<<"$SCRIPT
$1" | awk '$0 == "row" { n = 0; next } { rows[++n] = $0 } END { for (i = 1; i <= n; i++) print rows[i] }' |
        sed 's/^"//;s/"$//;s/""/"/g'
}
