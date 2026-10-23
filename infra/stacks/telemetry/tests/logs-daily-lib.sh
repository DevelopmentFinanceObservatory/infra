# shellcheck shell=bash
# Shared by load_from.test.sh and mcp_daily.test.sh, which source it after
# setting DIR to their own directory.

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
