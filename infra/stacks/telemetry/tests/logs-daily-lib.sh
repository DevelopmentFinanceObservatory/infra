# shellcheck shell=bash
# Shared by load_from.test.sh, mcp_daily.test.sh and
# website_requests_daily.test.sh, which source it after setting DIR to their
# own directory. script_rows also needs PROJECT, and the SCRIPT it runs.

# statements <pattern> [file]: the statements of <file> in sql, logs_daily.sql
# by default, that start with <pattern>, or with "!<pattern>" those that do
# not, each ending at a line that ends in ";", with comment lines dropped.
# Exits when none matches.
statements() {
    local file="${2:-logs_daily.sql}" pattern="$1" negate=0 found
    if [ "${pattern#!}" != "$pattern" ]; then
        pattern="${pattern#!}"
        negate=1
    fi
    found="$(awk -v pattern="^($pattern)" -v negate="$negate" '
        { buf = buf $0 "\n" }
        /;[[:space:]]*$/ {
            body = buf
            gsub(/(^|\n)[[:space:]]*--[^\n]*/, "", body)
            sub(/^[[:space:]]+/, "", body)
            if (body != "" && (body ~ pattern) != negate) printf "%s\n", body
            buf = ""
        }
    ' "$DIR/../sql/$file")"
    [ -n "$found" ] || {
        echo "${BASH_SOURCE[1]##*/}: no statement in $file matches $1" >&2
        exit 1
    }
    printf '%s\n' "$found"
}

# MCP_FUNCTION: sql/parse_mcp_line.sql as the temp function parse_mcp_line,
# for a script whose `${parse_mcp_line}` placeholder becomes parse_mcp_line.
# shellcheck disable=SC2034 # read by the tests that source this file
MCP_FUNCTION="CREATE TEMP FUNCTION parse_mcp_line(message STRING) AS (
$(cat "$DIR/../sql/parse_mcp_line.sql")
);"

# script_rows <query>: runs $SCRIPT and then <query>, whose one column is a
# JSON row named row, and prints each row. bq prints each statement of a
# script and its result, so the rows are those after the last header.
script_rows() {
    bq --quiet query --project_id="$PROJECT" --location=EU --use_legacy_sql=false \
        --format=csv --max_rows=1000 <<<"$SCRIPT
$1" | awk '$0 == "row" { n = 0; next } { rows[++n] = $0 } END { for (i = 1; i <= n; i++) print rows[i] }' |
        sed 's/^"//;s/"$//;s/""/"/g'
}
