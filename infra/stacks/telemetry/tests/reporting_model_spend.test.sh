#!/usr/bin/env bash
# Tests sql/reporting/model_spend_daily.sql against literal rows in Cloud
# Billing's standard usage cost export schema, cut to the fields the view
# reads, with two projects in spend_callers. Not wired into CI. Run by hand
# after touching the view:
#   infra/stacks/telemetry/tests/reporting_model_spend.test.sh [project]
#
# one-website is on the billing account and not in spend_callers, so its
# cost is left out. Days are UTC and relative to the current UTC day D, since
# the view keeps only days before yesterday. The rows at 05:00 and 08:00 on
# D-2 share a day, and the rows on D-1 and D are left out. Credits are
# negative and net_cost is cost plus credits.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"

# days_ago <n>: the UTC day n days before today, as BSD or GNU date prints it.
days_ago() { date -u -v-"$1"d +%F 2>/dev/null || date -u -d "$1 days ago" +%F; }
D3="$(days_ago 3)"
D2="$(days_ago 2)"

SOURCES="WITH
  billing AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<project STRUCT<id STRING>, service STRUCT<description STRING>,
      sku STRUCT<description STRING>, usage_start_time TIMESTAMP, cost FLOAT64, currency STRING,
      credits ARRAY<STRUCT<amount FLOAT64>>>>[
    (STRUCT('prod-fin-observatory'), STRUCT('Cloud Run'), STRUCT('CPU Allocation Time'),
      TIMESTAMP(CURRENT_DATE() - 3) + INTERVAL 10 HOUR, 1.5, 'USD', [STRUCT(-0.5)]),
    (STRUCT('prod-fin-observatory'), STRUCT('Cloud Run'), STRUCT('CPU Allocation Time'),
      TIMESTAMP(CURRENT_DATE() - 2) + INTERVAL 5 HOUR, 0.5, 'USD', ARRAY<STRUCT<amount FLOAT64>>[]),
    (STRUCT('prod-fin-observatory'), STRUCT('Cloud Run'), STRUCT('CPU Allocation Time'),
      TIMESTAMP(CURRENT_DATE() - 2) + INTERVAL 8 HOUR, 0.25, 'USD', ARRAY<STRUCT<amount FLOAT64>>[]),
    (STRUCT('gen-lang-client-0000000000'), STRUCT('Gemini API'), STRUCT('Gemini 3.8 Flash input tokens'),
      TIMESTAMP(CURRENT_DATE() - 3) + INTERVAL 12 HOUR, 2.0, 'USD', [STRUCT(-0.25), STRUCT(-0.25)]),
    (STRUCT('one-website'), STRUCT('Cloud Run'), STRUCT('CPU Allocation Time'),
      TIMESTAMP(CURRENT_DATE() - 3) + INTERVAL 12 HOUR, 100.0, 'USD', ARRAY<STRUCT<amount FLOAT64>>[]),
    (STRUCT('prod-fin-observatory'), STRUCT('Cloud Run'), STRUCT('CPU Allocation Time'),
      TIMESTAMP(CURRENT_DATE() - 1) + INTERVAL 23 HOUR, 4.0, 'USD', ARRAY<STRUCT<amount FLOAT64>>[]),
    (STRUCT('prod-fin-observatory'), STRUCT('Cloud Run'), STRUCT('CPU Allocation Time'),
      TIMESTAMP(CURRENT_DATE()), 8.0, 'USD', ARRAY<STRUCT<amount FLOAT64>>[])])
  )"
CALLERS="('gen-lang-client-0000000000', 'gemini-shared-key'), ('prod-fin-observatory', 'platform')"

check model_spend_daily \
    '{"day":"'"$D3"'","caller":"gemini-shared-key","service":"Gemini API","sku":"Gemini 3.8 Flash input tokens","cost":2,"credits":-0.5,"net_cost":1.5,"currency":"USD"}
{"day":"'"$D3"'","caller":"platform","service":"Cloud Run","sku":"CPU Allocation Time","cost":1.5,"credits":-0.5,"net_cost":1,"currency":"USD"}
{"day":"'"$D2"'","caller":"platform","service":"Cloud Run","sku":"CPU Allocation Time","cost":0.75,"credits":0,"net_cost":0.75,"currency":"USD"}' \
    "$(view_rows model_spend_daily 't.day, t.caller' billing=billing "callers=$CALLERS")"

finish reporting_model_spend.test.sh
