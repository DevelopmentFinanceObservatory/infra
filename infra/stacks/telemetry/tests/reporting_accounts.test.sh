#!/usr/bin/env bash
# Tests sql/reporting/accounts_daily.sql against literal rows in the website
# export's account_daily schema (dfo-website db/account-export.ts). Not wired
# into CI. Run by hand after touching the view:
#   infra/stacks/telemetry/tests/reporting_accounts.test.sh [project]
#
# The view reads the table straight, so the rows pass through with the
# columns day DATE, organisation STRING and accounts INT64. A source that
# renames or drops a column makes the query fail, so the dashboard breaks at
# the next apply and not on a silent null.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"

SOURCES="WITH
  account_daily AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<day DATE, organisation STRING, accounts INT64>>[
    (DATE '2026-10-05', 'one.org', 4),
    (DATE '2026-10-05', 'Personal email', 7),
    (DATE '2026-10-06', 'Other organisations', 2),
    (DATE '2026-10-06', 'one.org', 1),
    (DATE '2026-10-07', CAST(NULL AS STRING), 0)])
  )"

check accounts_daily \
    '{"day":"2026-10-05","organisation":"Personal email","accounts":7}
{"day":"2026-10-05","organisation":"one.org","accounts":4}
{"day":"2026-10-06","organisation":"Other organisations","accounts":2}
{"day":"2026-10-06","organisation":"one.org","accounts":1}
{"day":"2026-10-07","organisation":null,"accounts":0}' \
    "$(view_rows accounts_daily 't.day, t.organisation' accounts=account_daily)"

# A source with a column dropped or renamed must fail on that column.
broken_sources=(
    "organisation|day, accounts"
    "accounts|day, organisation"
    "organisation|day, organisation AS org, accounts"
    "accounts|day, organisation, accounts AS total"
)
for broken in "${broken_sources[@]}"; do
    column="${broken%%|*}"
    SOURCES="WITH
  account_daily AS (
    SELECT ${broken#*|} FROM UNNEST([STRUCT(DATE '2026-10-05' AS day, 'one.org' AS organisation, 4 AS accounts)])
  )"
    error="$(view_rows accounts_daily 't.day' accounts=account_daily 2>&1 | tr -s '[:space:]' ' ' || true)"
    check "accounts_daily over '${broken#*|}' fails on $column" \
        "Unrecognized name: $column" \
        "$(grep -o "Unrecognized name: $column" <<<"$error" | head -n 1 || true)"
done

finish reporting_accounts.test.sh
