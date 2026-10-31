# shellcheck shell=bash
# Shared by load-logs-backfill.sh and
# infra/stacks/telemetry/tests/mcp_daily.test.sh, so the test runs the code
# that fills the loader's mcp_daily scripts and reads their report. It holds
# the placeholder filling of infra/stacks/telemetry/sql/mcp_daily_preflight.sql
# and mcp_daily_history.sql, and the parse of the history script's report.

# mcp_set_refs <project> <cutoff>: sets what fill_mcp_sql puts in place of
# each placeholder, for <project>'s tables. The test sets the same variables
# to temp tables, a temp function and literal sources.
mcp_set_refs() {
    mcp_ref_live="\`$1.dfo_logs._AllLogs\`"
    mcp_ref_tables="\`$1.logs_daily.INFORMATION_SCHEMA.TABLES\`"
    mcp_ref_table="\`$1.logs_daily.mcp_daily\`"
    mcp_ref_parse="\`$1.logs_daily.parse_mcp_line\`"
    mcp_cutoff="$2"
}

# fill_mcp_sql [backfill]: the SQL on stdin with its placeholders replaced
# from the mcp_ref_* variables and mcp_cutoff, and ${backfill} replaced by the
# argument when given. The quoted replacements keep & and backslashes as
# written. Fails when a placeholder is left outside the comments.
fill_mcp_sql() {
    local sql
    sql="$(cat)"
    # shellcheck disable=SC2016 # the patterns are the template's literal placeholders
    sql=${sql//'`${live_source}`'/"$mcp_ref_live"}
    # shellcheck disable=SC2016
    sql=${sql//'`${dataset}.INFORMATION_SCHEMA.TABLES`'/"$mcp_ref_tables"}
    # shellcheck disable=SC2016
    sql=${sql//'`${dataset}.mcp_daily`'/"$mcp_ref_table"}
    # shellcheck disable=SC2016
    sql=${sql//'`${parse_mcp_line}`'/"$mcp_ref_parse"}
    # shellcheck disable=SC2016
    sql=${sql//'${cutoff}'/"$mcp_cutoff"}
    if [ "$#" -gt 0 ]; then
        # shellcheck disable=SC2016
        sql=${sql//'${backfill}'/"$1"}
    fi
    # The backfill query's header names its placeholder in a comment.
    if grep -v '^[[:space:]]*--' <<<"$sql" | grep -q '[$][{]'; then
        echo "fill_mcp_sql: a placeholder is left unreplaced." >&2
        return 1
    fi
    printf '%s\n' "$sql"
}

# mcp_report <output>: the "<day>,<calls>" lines of the history script's
# output, the rows of its final SELECT. bq prints each statement's result as
# CSV and errors to stdout too, so the rows are the lines that start with the
# marker column. An empty result prints no header.
mcp_report() {
    sed -n 's/^mcp_history_day,\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\},[0-9]\{1,\}\)$/\1/p' <<<"$1"
}
