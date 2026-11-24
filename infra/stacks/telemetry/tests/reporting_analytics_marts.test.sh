#!/usr/bin/env bash
# Tests the sql/reporting/<view>_analytics.sql templates, which the views in
# reporting_mart_views (reporting_views.tf) read under
# var.analytics_dbt_schedule_enabled, each against one literal row in its
# analytics table's contract (dbt/models/marts/models.yml in the analytics
# repository). The row puts its columns in reverse order and adds a column
# the view must leave out, so each check pins the view's columns and their
# order. Not wired into CI. Run by hand after touching a template:
#   infra/stacks/telemetry/tests/reporting_analytics_marts.test.sh [project]
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"

SOURCES="WITH
  mart AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<returning_sketch BYTES, active_sketch BYTES, day DATE, extra STRING>>[
    (CAST(NULL AS BYTES), b'\x01', DATE '2026-10-05', 'not selected')])
  )"
check account_returns_daily_analytics \
    '{"day":"2026-10-05","active_sketch":"AQ==","returning_sketch":null}' \
    "$(view_rows account_returns_daily_analytics 'TO_JSON_STRING(t)' table=mart)"

SOURCES="WITH
  mart AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<accounts INT64, organisation STRING, day DATE, extra STRING>>[
    (7, 'Personal email', DATE '2026-10-05', 'not selected')])
  )"
check accounts_daily_analytics \
    '{"day":"2026-10-05","organisation":"Personal email","accounts":7}' \
    "$(view_rows accounts_daily_analytics 'TO_JSON_STRING(t)' table=mart)"

SOURCES="WITH
  mart AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<cached_input_tokens INT64, latency_sketch BYTES, total_tokens INT64, level STRING, trace_name STRING, cost_usd FLOAT64, output_tokens INT64, input_tokens INT64, latency_p95_seconds FLOAT64, latency_p50_seconds FLOAT64, errors INT64, observations INT64, model STRING, name STRING, type STRING, day DATE, extra STRING>>[
    (40, b'\x02', 122, 'DEFAULT', 'turn', 0.625, 21, 101, 3.0, 2.0, 1, 2, 'gemini-3.8-flash', 'orchestrate', 'GENERATION', DATE '2026-10-05', 'not selected')])
  )"
check ai_observations_daily_analytics \
    '{"day":"2026-10-05","type":"GENERATION","name":"orchestrate","model":"gemini-3.8-flash","observations":2,"errors":1,"latency_p50_seconds":2,"latency_p95_seconds":3,"input_tokens":101,"output_tokens":21,"cost_usd":0.625,"trace_name":"turn","level":"DEFAULT","total_tokens":122,"latency_sketch":"Ag==","cached_input_tokens":40}' \
    "$(view_rows ai_observations_daily_analytics 'TO_JSON_STRING(t)' table=mart)"

SOURCES="WITH
  mart AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<cached_input_tokens INT64, errored BOOL, cost_usd FLOAT64, output_tokens INT64, input_tokens INT64, tool_calls INT64, generations INT64, time_to_first_token_seconds FLOAT64, latency_seconds FLOAT64, session_sketch BYTES, started_at TIMESTAMP, day DATE, extra STRING>>[
    (40, TRUE, 0.75, 25, 110, 1, 2, 1.5, 5.0, b'\x01', TIMESTAMP '2026-10-05 10:00:00+00', DATE '2026-10-05', 'not selected')])
  )"
check ai_turns_analytics \
    '{"day":"2026-10-05","started_at":"2026-10-05T10:00:00Z","session_sketch":"AQ==","latency_seconds":5,"time_to_first_token_seconds":1.5,"generations":2,"tool_calls":1,"input_tokens":110,"output_tokens":25,"cost_usd":0.75,"errored":true,"cached_input_tokens":40}' \
    "$(view_rows ai_turns_analytics 'TO_JSON_STRING(t)' table=mart)"

SOURCES="WITH
  mart AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<verified_bot_page_loads INT64, page_loads INT64, day DATE, extra STRING>>[
    (490, 812, DATE '2026-10-05', 'not selected')])
  )"
check cloudflare_daily_analytics \
    '{"day":"2026-10-05","page_loads":812,"verified_bot_page_loads":490}' \
    "$(view_rows cloudflare_daily_analytics 'TO_JSON_STRING(t)' table=mart)"

SOURCES="WITH
  mart AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<verified_bot_page_loads INT64, page_loads INT64, path STRING, day DATE, extra STRING>>[
    (3, 30, '/prototypes', DATE '2026-11-16', 'not selected')])
  )"
check cloudflare_pages_daily_analytics \
    '{"day":"2026-11-16","path":"/prototypes","page_loads":30,"verified_bot_page_loads":3}' \
    "$(view_rows cloudflare_pages_daily_analytics 'TO_JSON_STRING(t)' table=mart)"

SOURCES="WITH
  mart AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<users_sketch BYTES, declined_page_views INT64, page_views INT64, sessions INT64, active_users INT64, day DATE, extra STRING>>[
    (b'\x01', 2, 6, 4, 2, DATE '2026-10-07', 'not selected')])
  )"
check ga4_daily_analytics \
    '{"day":"2026-10-07","active_users":2,"sessions":4,"page_views":6,"declined_page_views":2,"users_sketch":"AQ=="}' \
    "$(view_rows ga4_daily_analytics 'TO_JSON_STRING(t)' table=mart)"

SOURCES="WITH
  mart AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<declined_page_views INT64, sessions INT64, page_views INT64, page_path STRING, day DATE, extra STRING>>[
    (1, 3, 4, '/a', DATE '2026-10-07', 'not selected')])
  )"
check ga4_pages_daily_analytics \
    '{"day":"2026-10-07","page_path":"/a","page_views":4,"sessions":3,"declined_page_views":1}' \
    "$(view_rows ga4_pages_daily_analytics 'TO_JSON_STRING(t)' table=mart)"

SOURCES="WITH
  mart AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<fetched_at TIMESTAMP, new_users INT64, total_users INT64, active_users INT64, range_end DATE, range_start DATE, range_kind STRING, extra STRING>>[
    (TIMESTAMP '2026-10-24 06:00:00+00', 214, 336, 292, DATE '2026-10-23', DATE '2026-10-19', 'week', 'not selected')])
  )"
check ga4_user_ranges_analytics \
    '{"range_kind":"week","range_start":"2026-10-19","range_end":"2026-10-23","active_users":292,"total_users":336,"new_users":214,"fetched_at":"2026-10-24T06:00:00Z"}' \
    "$(view_rows ga4_user_ranges_analytics 'TO_JSON_STRING(t)' table=mart)"

SOURCES="WITH
  mart AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<currency STRING, net_cost FLOAT64, credits FLOAT64, cost FLOAT64, sku STRING, service STRING, caller STRING, day DATE, extra STRING>>[
    ('USD', 1.0, -0.5, 1.5, 'CPU Allocation Time', 'Cloud Run', 'platform', DATE '2026-10-07', 'not selected')])
  )"
check model_spend_daily_analytics \
    '{"day":"2026-10-07","caller":"platform","service":"Cloud Run","sku":"CPU Allocation Time","cost":1.5,"credits":-0.5,"net_cost":1,"currency":"USD"}' \
    "$(view_rows model_spend_daily_analytics 'TO_JSON_STRING(t)' table=mart)"

SOURCES="WITH
  mart AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<users_sketch BYTES, visitors_sketch BYTES, events INT64, signed_in BOOL, page STRING, event STRING, day DATE, extra STRING>>[
    (CAST(NULL AS BYTES), b'\x01', 2, TRUE, '/studio/:id', 'studio.prompt', DATE '2026-10-05', 'not selected')])
  )"
check product_events_daily_analytics \
    '{"day":"2026-10-05","event":"studio.prompt","page":"/studio/:id","signed_in":true,"events":2,"visitors_sketch":"AQ==","users_sketch":null}' \
    "$(view_rows product_events_daily_analytics 'TO_JSON_STRING(t)' table=mart)"

SOURCES="WITH
  mart AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<sum_position FLOAT64, impressions INT64, clicks INT64, day DATE, extra STRING>>[
    (14.0, 25, 3, DATE '2026-10-06', 'not selected')])
  )"
check search_console_daily_analytics \
    '{"day":"2026-10-06","clicks":3,"impressions":25,"sum_position":14}' \
    "$(view_rows search_console_daily_analytics 'TO_JSON_STRING(t)' table=mart)"

SOURCES="WITH
  mart AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<sum_position FLOAT64, impressions INT64, clicks INT64, url STRING, day DATE, extra STRING>>[
    (3.0, 25, 4, 'https://developmentfinance.org/a', DATE '2026-10-06', 'not selected')])
  )"
check search_console_pages_analytics \
    '{"day":"2026-10-06","url":"https://developmentfinance.org/a","clicks":4,"impressions":25,"sum_position":3}' \
    "$(view_rows search_console_pages_analytics 'TO_JSON_STRING(t)' table=mart)"

finish reporting_analytics_marts.test.sh
