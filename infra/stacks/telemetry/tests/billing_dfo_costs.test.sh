#!/usr/bin/env bash
# Tests sql/billing_dfo_costs.sql, the view billing_dfo.costs, against literal
# rows in Cloud Billing's standard usage cost export schema, cut to the fields
# the view reads, with two projects in spend_callers. Not wired into CI. Run by
# hand after touching the view:
#   infra/stacks/telemetry/tests/billing_dfo_costs.test.sh [project]
#
# one-website is on the billing account and not in spend_callers, so its line
# is left out. Each kept line keeps its own row, labelled with its caller, and
# its credits are summed, 0 for a line with none.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="$DIR/../sql"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"

SOURCES="WITH
  billing AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<project STRUCT<id STRING>, service STRUCT<description STRING>,
      sku STRUCT<description STRING>, usage_start_time TIMESTAMP, export_time TIMESTAMP, cost FLOAT64,
      currency STRING, credits ARRAY<STRUCT<amount FLOAT64>>>>[
    (STRUCT('prod-fin-observatory'), STRUCT('Cloud Run'), STRUCT('CPU Allocation Time'),
      TIMESTAMP '2026-11-01 10:00:00', TIMESTAMP '2026-11-01 14:00:00', 1.5, 'USD', [STRUCT(-0.5)]),
    (STRUCT('prod-fin-observatory'), STRUCT('Cloud Run'), STRUCT('CPU Allocation Time'),
      TIMESTAMP '2026-11-01 11:00:00', TIMESTAMP '2026-11-01 15:00:00', 0.5, 'USD', ARRAY<STRUCT<amount FLOAT64>>[]),
    (STRUCT('gen-lang-client-0000000000'), STRUCT('Gemini API'), STRUCT('Gemini 3.8 Flash input tokens'),
      TIMESTAMP '2026-11-01 12:00:00', TIMESTAMP '2026-11-01 16:00:00', 2.0, 'USD', [STRUCT(-0.25), STRUCT(-0.25)]),
    (STRUCT('one-website'), STRUCT('Cloud Run'), STRUCT('CPU Allocation Time'),
      TIMESTAMP '2026-11-01 12:00:00', TIMESTAMP '2026-11-01 16:00:00', 100.0, 'USD', ARRAY<STRUCT<amount FLOAT64>>[])])
  )"
CALLERS="('gen-lang-client-0000000000', 'gemini-shared-key'), ('prod-fin-observatory', 'platform')"

check billing_dfo_costs \
    '{"caller":"gemini-shared-key","project_id":"gen-lang-client-0000000000","service":"Gemini API","sku":"Gemini 3.8 Flash input tokens","usage_start_time":"2026-11-01T12:00:00Z","export_time":"2026-11-01T16:00:00Z","cost":2,"currency":"USD","credits":-0.5}
{"caller":"platform","project_id":"prod-fin-observatory","service":"Cloud Run","sku":"CPU Allocation Time","usage_start_time":"2026-11-01T10:00:00Z","export_time":"2026-11-01T14:00:00Z","cost":1.5,"currency":"USD","credits":-0.5}
{"caller":"platform","project_id":"prod-fin-observatory","service":"Cloud Run","sku":"CPU Allocation Time","usage_start_time":"2026-11-01T11:00:00Z","export_time":"2026-11-01T15:00:00Z","cost":0.5,"currency":"USD","credits":0}' \
    "$(view_rows billing_dfo_costs 't.caller, t.usage_start_time' billing=billing "callers=$CALLERS")"

finish billing_dfo_costs.test.sh
