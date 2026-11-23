#!/usr/bin/env bash
# Tests the sql/reporting/metrics_*.sql views against literal rows in the
# schemas of the analytics marts they read. Not wired into CI. Run by hand
# after touching a view:
#   infra/stacks/telemetry/tests/reporting_metrics.test.sh [project]
#
# Each view keeps complete ISO weeks, so every mart holds a row for the week
# of CURRENT_DATE() that no view may return. A surface-keyed view also keeps
# only the surface-weeks int_surface_weeks_observed marks observed: the
# website is unobserved in 2026-10-19 and the unknown surface in 2026-10-05.
# The website is observed with no reads in 2026-10-26, which gives each key
# kind it holds a zero row. A key view returns counts, so no consumer key or
# host reaches a row.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/stacks/telemetry/tests/reporting-lib.sh
. "$DIR/reporting-lib.sh"

CUR="DATE_TRUNC(CURRENT_DATE(), ISOWEEK)"

SOURCES="WITH
  int_surface_weeks_observed AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<surface STRING, iso_week DATE, observed BOOL, askers_partly_unnamed BOOL, weeks_observed_of_last_4 INT64, weeks_observed_of_last_8 INT64>>[
    ('website', '2026-10-05', true, false, 1, 1),
    ('website', '2026-10-12', true, true, 2, 2),
    ('website', '2026-10-19', false, false, 2, 2),
    ('website', '2026-10-26', true, false, 3, 3),
    ('website', $CUR, true, false, 3, 3),
    ('api', '2026-10-05', true, false, 1, 1),
    ('api', '2026-10-12', true, false, 2, 2),
    ('mcp', '2026-10-12', true, false, 2, 2),
    ('studio', '2026-10-05', true, false, 1, 1),
    ('studio', '2026-10-12', true, false, 2, 2),
    ('unknown', '2026-10-05', false, false, 0, 0)])
  ),
  regular_consumers_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<iso_week DATE, surface STRING, consumer STRING, consumer_kind STRING, consumer_class STRING, active_this_week BOOL, is_regular BOOL, is_regular_interim BOOL>>[
    ('2026-10-05', 'website', 'a1', 'visitor', 'external', true, false, false),
    ('2026-10-12', 'website', 'a1', 'visitor', 'external', true, true, true),
    ('2026-10-12', 'website', 'a2', 'visitor', 'external', true, false, true),
    ('2026-10-12', 'website', 'a3', 'visitor', 'external', false, false, false),
    ('2026-10-12', 'website', 'k1', 'account', 'one_campaign', true, true, true),
    ('2026-10-12', 'api', 'i1', 'ip', 'external', true, false, false),
    ($CUR, 'website', 'a1', 'visitor', 'external', true, true, true)])
  ),
  dependence_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<iso_week DATE, surface STRING, consumer_class STRING, consumers INT64, regular_consumers INT64, regular_consumers_interim INT64, indicator_uses INT64, regular_uses_share FLOAT64, regular_interim_uses_share FLOAT64, top_ten_uses_share FLOAT64, askers_partly_unnamed BOOL>>[
    ('2026-10-12', 'website', 'external', 40, 5, 9, 200, 0.5, 0.75, 0.25, true),
    ('2026-10-19', 'website', 'external', 41, 6, 10, 210, 0.5, 0.75, 0.25, false),
    ($CUR, 'website', 'external', 42, 7, 11, 220, 0.5, 0.75, 0.25, false)])
  ),
  consumer_cohorts_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<cohort_week DATE, surface STRING, consumer_class STRING, cohort_size INT64, askers_partly_unnamed BOOL, retained_week_4 INT64, retention_week_4 FLOAT64, retained_week_8 INT64, retention_week_8 FLOAT64, retained_week_12 INT64, retention_week_12 FLOAT64>>[
    ('2026-10-05', 'website', 'external', 10, false, 4, 0.4, 2, 0.2, NULL, NULL),
    ('2026-10-19', 'website', 'external', 12, false, NULL, NULL, NULL, NULL, NULL, NULL),
    ($CUR, 'website', 'external', 3, false, NULL, NULL, NULL, NULL, NULL, NULL)])
  ),
  standing_pulls_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<iso_week DATE, surface STRING, consumer_class STRING, standing_pull_consumers INT64, standing_pulls INT64, weeks_observed_of_last_8 INT64>>[
    ('2026-10-12', 'api', 'external', 3, 8, 2),
    ('2026-10-05', 'unknown', 'external', 1, 1, 0),
    ($CUR, 'api', 'external', 3, 8, 3)])
  ),
  regular_organisations_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<iso_week DATE, surface STRING, audience STRING, organisation_group STRING, organisations INT64, organisations_interim INT64, accounts INT64, regular_accounts INT64, regular_accounts_interim INT64, label_as_of_first_snapshot BOOL>>[
    ('2026-10-12', 'studio', 'external', 'Named organisations', 4, 6, 20, 7, 9, false),
    ('2026-10-12', 'studio', 'external', 'Other organisations', NULL, NULL, 8, 1, 2, false),
    ('2026-10-19', 'studio', 'external', 'Named organisations', 5, 7, 21, 8, 10, false),
    ($CUR, 'studio', 'external', 'Named organisations', 5, 7, 21, 8, 10, false)])
  ),
  spec_uses_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<iso_week DATE, surface STRING, kind STRING, consumer STRING, spec_id STRING>>[
    ('2026-10-12', 'studio', 'use', 'k1', 's1'),
    ('2026-10-12', 'studio', 'use', 'k1', 's2'),
    ('2026-10-12', 'studio', 'use', 'k2', 's1'),
    ('2026-10-12', 'studio', 'fetch', 'k2', 's1'),
    ('2026-10-12', 'studio', 'use', 'k1', 's1'),
    ($CUR, 'studio', 'use', 'k1', 's1')])
  ),
  indicator_uses_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<iso_week DATE, surface STRING, kind STRING, consumer STRING, client_family STRING, indicator STRING>>[
    ('2026-10-12', 'mcp', 'use', 'k1', 'Claude Code', 'i1'),
    ('2026-10-12', 'mcp', 'use', 'k1', 'Claude Code', 'i2'),
    ('2026-10-12', 'mcp', 'use', 'k1', 'curl', 'i1'),
    ('2026-10-12', 'mcp', 'use', 'k2', NULL, 'i1'),
    ('2026-10-05', 'unknown', 'use', 'k3', 'curl', 'i1'),
    ($CUR, 'mcp', 'use', 'k1', 'curl', 'i1')])
  ),
  delivery_topics_daily AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<day DATE, surface STRING, axis STRING, topic_id STRING, deliveries FLOAT64>>[
    ('2026-10-12', 'api', 'subject', 'health', 1.5),
    ('2026-10-14', 'api', 'subject', 'health', 2.0),
    ('2026-10-14', 'api', 'subject', 'trade', 1.0),
    ('2026-10-14', 'direct', 'subject', 'health', 9.0),
    (CURRENT_DATE(), 'api', 'subject', 'health', 5.0)])
  ),
  topic_taxonomy AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<axis STRING, topic_id STRING, name STRING>>[
    ('subject', 'health', 'Health'),
    ('finance_kind', 'grant', 'Grants')])
  ),
  chat_host_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<iso_week DATE, host STRING, data_calls INT64, indicators INT64>>[
    ('2026-10-05', 'ChatGPT', 3, 2),
    ('2026-10-12', 'ChatGPT', 7, 4),
    ('2026-10-12', 'Claude.ai', 5, 3),
    ('2026-10-19', 'Gemini', 1, 1),
    ($CUR, 'ChatGPT', 9, 9)])
  ),
  assistant_fetches_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<agent_name STRING, kind STRING, iso_week DATE, requests INT64, retrievals INT64>>[
    ('ChatGPT-User', 'page', '2026-10-05', 6, 5),
    ('ChatGPT-User', 'api', '2026-10-12', 2, 2),
    ('ChatGPT-User', 'page', '2026-10-19', 3, 3),
    ('ChatGPT-User', 'page', $CUR, 4, 4)])
  ),
  crawler_reads_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<agent_name STRING, kind STRING, iso_week DATE, requests INT64, retrievals INT64>>[
    ('Googlebot', 'page', '2026-10-05', 60, 50),
    ('GPTBot', 'rsc', '2026-10-12', 20, 0),
    ('Googlebot', 'page', '2026-10-19', 30, 30),
    ('Googlebot', 'page', $CUR, 40, 40)])
  ),
  reach_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<iso_week DATE, kind STRING, host STRING, opens INT64, unknown_opens INT64>>[
    ('2026-10-12', 'embed', 'a.example', 5, 1),
    ('2026-10-12', 'embed', 'b.example', 3, 0),
    ('2026-10-12', 'share', 'a.example', 2, 0),
    ($CUR, 'share', 'a.example', 9, 0)])
  ),
  embedding_sites_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<iso_week DATE, host STRING, opens_this_week INT64, is_regular BOOL>>[
    ('2026-10-12', 'a.example', 5, true),
    ('2026-10-12', 'b.example', 3, false),
    ('2026-10-19', 'a.example', 4, true),
    ($CUR, 'a.example', 9, true)])
  ),
  public_repos_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<iso_week DATE, sdk_repos INT64, sdk_new_repos INT64, mcp_repos INT64, mcp_new_repos INT64, any_query_failed BOOL, any_capped BOOL, any_incomplete BOOL>>[
    ('2026-10-12', 10, 2, 4, 1, false, false, false),
    ($CUR, 11, 1, 4, 0, false, false, false)])
  ),
  trust_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<iso_week DATE, slot_source STRING, share_era STRING, run_status STRING, shares INT64, derived_cards INT64, comparable INT64, same INT64, different INT64, comparable_match_rate FLOAT64, comparable_coverage FLOAT64, dataset_cards INT64, confirmed INT64, still_current INT64, moved INT64, confirmed_still_current_rate FLOAT64>>[
    ('2026-10-12', 'recent', 'v2', 'complete', 20, 15, 10, 9, 1, 0.9, 0.5, 8, 6, 5, 1, 0.8333),
    ('2026-10-12', 'recent', 'v2', 'partial', 5, 3, 2, 2, 0, 1.0, 0.5, 2, 1, 1, 0, 1.0),
    ($CUR, 'recent', 'v2', 'complete', 1, 1, 1, 1, 0, 1.0, 1.0, 1, 1, 1, 0, 1.0)])
  ),
  consistency_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<iso_week DATE, frames_recomputed INT64, frames_seen_before INT64, frames_consistent INT64, consistent_share FLOAT64, content_version_moved INT64, engine_changed INT64>>[
    ('2026-10-12', 30, 20, 19, 0.95, 1, 0),
    ($CUR, 5, 4, 4, 1.0, 0, 0)])
  ),
  requests_daily AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<day DATE, service STRING, requests INT64, status_4xx INT64, status_5xx INT64>>[
    ('2026-10-12', 'website', 100, 10, 1),
    ('2026-10-13', 'website', 300, 20, 3),
    ('2026-10-12', 'api', 0, 0, 0),
    (CURRENT_DATE(), 'website', 50, 0, 0)])
  ),
  supply_coverage_daily AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<day DATE, source_key STRING, coverage STRING>>[
    ('2026-10-12', 's1', 'curated'),
    ('2026-10-12', 's2', 'curated'),
    ('2026-10-12', 's3', 'missing'),
    (CURRENT_DATE(), 's1', 'curated')])
  ),
  catalogue_daily AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<day DATE, catalogue_version STRING, sources INT64, datasets INT64, indicators INT64, dfo_sources INT64, dfo_datasets INT64, dfo_indicators INT64, data_commons_sources INT64, data_commons_datasets INT64, data_commons_indicators INT64>>[
    ('2026-10-12', 'v7', 10, 20, 300, 4, 8, 100, 6, 12, 200),
    (CURRENT_DATE(), 'v8', 11, 21, 301, 5, 9, 101, 6, 12, 200)])
  ),
  topic_demand_weekly AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<iso_week DATE, axis STRING, topic_id STRING, suppressed BOOL, turns FLOAT64, unmet_turns FLOAT64, unmet_rate FLOAT64>>[
    ('2026-10-12', 'subject', 'health', false, 12.0, 3.0, 0.25),
    ('2026-10-12', 'subject', 'other', true, NULL, NULL, NULL),
    ('2026-10-19', 'subject', 'health', false, 8.0, 2.0, 0.25),
    ($CUR, 'subject', 'health', false, 9.0, 1.0, 0.11)])
  ),
  int_variable_topics AS (
    SELECT * FROM UNNEST(ARRAY<STRUCT<variable_dcid STRING, main_subject STRING, finance_kind STRING, stale BOOL>>[
    ('v1', 'health', 'grant', false),
    ('v2', 'health', 'loan', false),
    ('v3', 'health', 'grant', true),
    ('v4', 'trade', 'grant', false)])
  )"

# metrics_rows <view> <order by>: the view's rows as JSON, with each
# placeholder bound to the CTE of the same name in SOURCES.
metrics_rows() {
    view_rows "$1" "$2" \
        assistant_fetches_weekly=assistant_fetches_weekly catalogue_daily=catalogue_daily \
        chat_host_weekly=chat_host_weekly consistency_weekly=consistency_weekly \
        consumer_cohorts_weekly=consumer_cohorts_weekly crawler_reads_weekly=crawler_reads_weekly \
        delivery_topics_daily=delivery_topics_daily dependence_weekly=dependence_weekly \
        embedding_sites_weekly=embedding_sites_weekly indicator_uses_weekly=indicator_uses_weekly \
        int_surface_weeks_observed=int_surface_weeks_observed int_variable_topics=int_variable_topics \
        public_repos_weekly=public_repos_weekly reach_weekly=reach_weekly \
        regular_consumers_weekly=regular_consumers_weekly regular_organisations_weekly=regular_organisations_weekly \
        requests_daily=requests_daily spec_uses_weekly=spec_uses_weekly \
        standing_pulls_weekly=standing_pulls_weekly supply_coverage_daily=supply_coverage_daily \
        topic_demand_weekly=topic_demand_weekly topic_taxonomy=topic_taxonomy trust_weekly=trust_weekly
}

check metrics_regular_consumers_weekly \
    '{"surface":"api","iso_week":"2026-10-12","consumer_kind":"ip","consumer_class":"external","active_consumers":1,"regular_2_of_4":0,"regular_3_of_8":0,"weeks_observed_of_last_4":2,"weeks_observed_of_last_8":2,"askers_partly_unnamed":false}
{"surface":"website","iso_week":"2026-10-05","consumer_kind":"visitor","consumer_class":"external","active_consumers":1,"regular_2_of_4":0,"regular_3_of_8":0,"weeks_observed_of_last_4":1,"weeks_observed_of_last_8":1,"askers_partly_unnamed":false}
{"surface":"website","iso_week":"2026-10-12","consumer_kind":"account","consumer_class":"one_campaign","active_consumers":1,"regular_2_of_4":1,"regular_3_of_8":1,"weeks_observed_of_last_4":2,"weeks_observed_of_last_8":2,"askers_partly_unnamed":true}
{"surface":"website","iso_week":"2026-10-12","consumer_kind":"visitor","consumer_class":"external","active_consumers":2,"regular_2_of_4":2,"regular_3_of_8":1,"weeks_observed_of_last_4":2,"weeks_observed_of_last_8":2,"askers_partly_unnamed":true}
{"surface":"website","iso_week":"2026-10-26","consumer_kind":"account","consumer_class":"one_campaign","active_consumers":0,"regular_2_of_4":0,"regular_3_of_8":0,"weeks_observed_of_last_4":3,"weeks_observed_of_last_8":3,"askers_partly_unnamed":false}
{"surface":"website","iso_week":"2026-10-26","consumer_kind":"visitor","consumer_class":"external","active_consumers":0,"regular_2_of_4":0,"regular_3_of_8":0,"weeks_observed_of_last_4":3,"weeks_observed_of_last_8":3,"askers_partly_unnamed":false}' \
    "$(metrics_rows metrics_regular_consumers_weekly 't.surface, t.iso_week, t.consumer_kind, t.consumer_class')"

check metrics_dependence_weekly \
    '{"surface":"website","iso_week":"2026-10-12","consumer_class":"external","consumers":40,"regular_2_of_4":9,"regular_3_of_8":5,"indicator_uses":200,"top_ten_uses_share":0.25,"regular_2_of_4_uses_share":0.75,"regular_3_of_8_uses_share":0.5,"askers_partly_unnamed":true}' \
    "$(metrics_rows metrics_dependence_weekly 't.surface, t.iso_week, t.consumer_class')"

check metrics_consumer_cohorts_weekly \
    '{"surface":"website","cohort_week":"2026-10-05","consumer_class":"external","cohort_size":10,"retained_week_4":4,"retention_week_4":0.4,"retained_week_8":2,"retention_week_8":0.2,"retained_week_12":null,"retention_week_12":null,"askers_partly_unnamed":false}' \
    "$(metrics_rows metrics_consumer_cohorts_weekly 't.surface, t.cohort_week')"

check metrics_standing_pulls_weekly \
    '{"surface":"api","iso_week":"2026-10-12","consumer_class":"external","standing_pull_consumers":3,"standing_pulls":8,"weeks_observed_of_last_8":2}' \
    "$(metrics_rows metrics_standing_pulls_weekly 't.surface, t.iso_week')"

check metrics_regular_organisations_weekly \
    '{"surface":"studio","iso_week":"2026-10-12","audience":"external","organisation_group":"Named organisations","organisations_2_of_4":6,"organisations_3_of_8":4,"accounts":20,"regular_accounts_2_of_4":9,"regular_accounts_3_of_8":7,"label_as_of_first_snapshot":false}
{"surface":"studio","iso_week":"2026-10-12","audience":"external","organisation_group":"Other organisations","organisations_2_of_4":null,"organisations_3_of_8":null,"accounts":8,"regular_accounts_2_of_4":2,"regular_accounts_3_of_8":1,"label_as_of_first_snapshot":false}' \
    "$(metrics_rows metrics_regular_organisations_weekly 't.surface, t.iso_week, t.organisation_group')"

check metrics_spec_uses_weekly \
    '{"surface":"studio","iso_week":"2026-10-12","kind":"fetch","consumers":1,"dataset_uses":1,"specs":1}
{"surface":"studio","iso_week":"2026-10-12","kind":"use","consumers":2,"dataset_uses":3,"specs":2}' \
    "$(metrics_rows metrics_spec_uses_weekly 't.iso_week, t.kind')"

check metrics_indicator_uses_weekly \
    '{"surface":"mcp","iso_week":"2026-10-12","kind":"use","client_family":"Claude Code","consumers":1,"indicator_uses":2,"indicators":2}
{"surface":"mcp","iso_week":"2026-10-12","kind":"use","client_family":"all","consumers":2,"indicator_uses":3,"indicators":2}
{"surface":"mcp","iso_week":"2026-10-12","kind":"use","client_family":"curl","consumers":1,"indicator_uses":1,"indicators":1}
{"surface":"mcp","iso_week":"2026-10-12","kind":"use","client_family":"unknown","consumers":1,"indicator_uses":1,"indicators":1}' \
    "$(metrics_rows metrics_indicator_uses_weekly 't.kind, t.client_family')"

check metrics_delivery_topics_daily \
    '{"surface":"api","iso_week":"2026-10-12","axis":"subject","topic_id":"health","topic_name":"Health","deliveries":3.5}
{"surface":"api","iso_week":"2026-10-12","axis":"subject","topic_id":"trade","topic_name":"trade","deliveries":1}' \
    "$(metrics_rows metrics_delivery_topics_daily 't.surface, t.iso_week, t.topic_id')"

check metrics_chat_host_weekly \
    '{"iso_week":"2026-10-12","host":"ChatGPT","data_calls":7,"indicators":4}
{"iso_week":"2026-10-12","host":"Claude.ai","data_calls":5,"indicators":3}' \
    "$(metrics_rows metrics_chat_host_weekly 't.iso_week, t.host')"

check metrics_assistant_fetches_weekly \
    '{"iso_week":"2026-10-05","agent_name":"ChatGPT-User","kind":"page","requests":6,"retrievals":5}
{"iso_week":"2026-10-12","agent_name":"ChatGPT-User","kind":"api","requests":2,"retrievals":2}' \
    "$(metrics_rows metrics_assistant_fetches_weekly 't.iso_week, t.kind')"

check metrics_crawler_reads_weekly \
    '{"iso_week":"2026-10-05","agent_name":"Googlebot","kind":"page","requests":60,"retrievals":50}
{"iso_week":"2026-10-12","agent_name":"GPTBot","kind":"rsc","requests":20,"retrievals":0}' \
    "$(metrics_rows metrics_crawler_reads_weekly 't.iso_week, t.kind')"

check metrics_reach_weekly \
    '{"iso_week":"2026-10-12","kind":"embed","opens":8,"unknown_opens":1,"hosts":2}
{"iso_week":"2026-10-12","kind":"share","opens":2,"unknown_opens":0,"hosts":1}' \
    "$(metrics_rows metrics_reach_weekly 't.kind')"

check metrics_embedding_sites_weekly \
    '{"iso_week":"2026-10-12","sites":2,"regular_sites":1,"opens":8}
{"iso_week":"2026-10-19","sites":1,"regular_sites":1,"opens":4}' \
    "$(metrics_rows metrics_embedding_sites_weekly 't.iso_week')"

check metrics_public_repos_weekly \
    '{"iso_week":"2026-10-12","sdk_repos":10,"sdk_new_repos":2,"mcp_repos":4,"mcp_new_repos":1,"any_query_failed":false,"any_capped":false,"any_incomplete":false}' \
    "$(metrics_rows metrics_public_repos_weekly 't.iso_week')"

check metrics_trust_weekly \
    '{"iso_week":"2026-10-12","slot_source":"recent","share_era":"v2","shares":20,"derived_cards":15,"comparable":10,"same":9,"different":1,"comparable_match_rate":0.9,"comparable_coverage":0.5,"dataset_cards":8,"confirmed":6,"still_current":5,"moved":1,"confirmed_still_current_rate":0.8333}' \
    "$(metrics_rows metrics_trust_weekly 't.iso_week')"

check metrics_consistency_weekly \
    '{"iso_week":"2026-10-12","frames_recomputed":30,"frames_seen_before":20,"frames_consistent":19,"consistent_share":0.95,"content_version_moved":1,"engine_changed":0}' \
    "$(metrics_rows metrics_consistency_weekly 't.iso_week')"

check metrics_requests_daily \
    '{"service":"api","iso_week":"2026-10-12","days":1,"requests":0,"status_4xx":0,"status_5xx":0,"availability":null}
{"service":"website","iso_week":"2026-10-12","days":2,"requests":400,"status_4xx":30,"status_5xx":4,"availability":0.99}' \
    "$(metrics_rows metrics_requests_daily 't.service')"

check metrics_supply_coverage_daily \
    '{"day":"2026-10-12","coverage":"curated","sources":2}
{"day":"2026-10-12","coverage":"missing","sources":1}' \
    "$(metrics_rows metrics_supply_coverage_daily 't.day, t.coverage')"

check metrics_catalogue_daily \
    '{"day":"2026-10-12","catalogue_version":"v7","sources":10,"datasets":20,"indicators":300,"dfo_sources":4,"dfo_datasets":8,"dfo_indicators":100,"data_commons_sources":6,"data_commons_datasets":12,"data_commons_indicators":200}' \
    "$(metrics_rows metrics_catalogue_daily 't.day')"

check metrics_topic_demand_weekly \
    '{"iso_week":"2026-10-12","axis":"subject","topic_id":"health","topic_name":"Health","suppressed":false,"turns":12,"unmet_turns":3,"unmet_rate":0.25}
{"iso_week":"2026-10-12","axis":"subject","topic_id":"other","topic_name":"other","suppressed":true,"turns":null,"unmet_turns":null,"unmet_rate":null}' \
    "$(metrics_rows metrics_topic_demand_weekly 't.iso_week, t.topic_id')"

check metrics_variable_topics \
    '{"axis":"finance_kind","topic_id":"grant","topic_name":"Grants","variables":2}
{"axis":"finance_kind","topic_id":"loan","topic_name":"loan","variables":1}
{"axis":"subject","topic_id":"health","topic_name":"Health","variables":2}
{"axis":"subject","topic_id":"trade","topic_name":"trade","variables":1}' \
    "$(metrics_rows metrics_variable_topics 't.axis, t.topic_id')"

finish reporting_metrics.test.sh
