# The views the team dashboard reads, in dfo_reporting. Each view's query is
# a template under sql/reporting, and tests/reporting_*.test.sh run each one
# over literal source rows. Each view reads one source group, and is created
# only once var.reporting_sources lists that group, since a view cannot name
# a table that does not exist yet. Readers of dfo_reporting get no access to
# the sources, so each view is authorised on every dataset it reads.
#
# The logs, mcp, website_requests and website_pages views read the day tables
# the logs_daily scheduled query writes. var.analytics_dbt_schedule_enabled
# disables that query (logs_daily.tf), so under the same switch they read the
# analytics dbt build's tables of the same name in the analytics dataset,
# which carry the same columns, and are authorised on that dataset instead.
# README "Analytics jobs" gives the parity check to run before the switch.
#
# Under the same switch every other view in reporting_mart_views reads the
# analytics build's table of its own name through
# sql/reporting/<view>_analytics.sql, which selects the view's columns, so
# every reporting view reads the one dbt pipeline. The dbt models apply the
# rules of the views' own templates, which the views keep while the switch is
# off.
locals {
  # The dataset holding the log-fed day tables the views read.
  reporting_log_dataset = var.analytics_dbt_schedule_enabled ? google_bigquery_dataset.analytics["analytics"].dataset_id : google_bigquery_dataset.logs_daily.dataset_id

  # The datasets each source group's views read. Its keys are the groups
  # var.reporting_sources may list (variables.tf). website_export and
  # langfuse_export are created by the website and ai stacks, the GA4 export
  # dataset by the GA4 BigQuery link, and the billing export dataset by the
  # foundation stack.
  reporting_source_datasets = {
    logs             = [local.reporting_log_dataset]
    mcp              = [local.reporting_log_dataset]
    website_requests = [local.reporting_log_dataset]
    # analytics.website_page_views_daily already joins the rebuilt history.
    website_pages    = var.analytics_dbt_schedule_enabled ? [local.reporting_log_dataset] : [local.reporting_log_dataset, google_bigquery_dataset.web_history.dataset_id]
    website          = var.analytics_dbt_schedule_enabled ? [local.reporting_analytics_dataset] : ["website_export"]
    accounts         = var.analytics_dbt_schedule_enabled ? [local.reporting_analytics_dataset] : ["website_export"]
    langfuse         = var.analytics_dbt_schedule_enabled ? [local.reporting_analytics_dataset] : ["langfuse_export"]
    ga4              = var.analytics_dbt_schedule_enabled ? [local.reporting_analytics_dataset] : [var.ga4_export_dataset, google_bigquery_dataset.web_history.dataset_id]
    search_console   = var.analytics_dbt_schedule_enabled ? [local.reporting_analytics_dataset] : [google_bigquery_dataset.searchconsole.dataset_id, google_bigquery_dataset.web_history.dataset_id]
    cloudflare       = var.analytics_dbt_schedule_enabled ? [local.reporting_analytics_dataset] : [google_bigquery_dataset.web_history.dataset_id]
    cloudflare_pages = var.analytics_dbt_schedule_enabled ? [local.reporting_analytics_dataset] : [google_bigquery_dataset.web_history.dataset_id]
    billing          = var.analytics_dbt_schedule_enabled ? [local.reporting_analytics_dataset] : [var.billing_export_dataset]
    # The metrics views read the marts the analytics dbt build writes.
    metrics = [local.reporting_analytics_dataset]
  }

  reporting_analytics_dataset = google_bigquery_dataset.analytics["analytics"].dataset_id

  # The views that read the analytics table of their own name under
  # var.analytics_dbt_schedule_enabled, each through
  # sql/reporting/<view>_analytics.sql.
  reporting_mart_views = [
    "account_returns_daily",
    "accounts_daily",
    "ai_observations_daily",
    "ai_turns",
    "cloudflare_daily",
    "cloudflare_pages_daily",
    "ga4_daily",
    "ga4_pages_daily",
    "ga4_user_ranges",
    "model_spend_daily",
    "product_events_daily",
    "search_console_daily",
    "search_console_pages",
  ]

  reporting_log_ref = "${var.project_id}.${local.reporting_log_dataset}"
  web_history_ref   = "${var.project_id}.${google_bigquery_dataset.web_history.dataset_id}"
  langfuse_ref      = "${var.project_id}.langfuse_export.observations"
  # events_2* matches the daily events_YYYYMMDD tables and leaves out
  # events_intraday_* should streaming export ever be turned on, since those
  # repeat the day's events.
  ga4_events_ref = "${var.project_id}.${var.ga4_export_dataset}.events_2*"

  # The views of the DFO Metrics dashboard, one per analytics mart. Each
  # template names its tables as ${table} placeholders, filled from
  # metrics_table_refs.
  metrics_ref = "${var.project_id}.${google_bigquery_dataset.analytics["analytics"].dataset_id}"
  metrics_table_refs = {
    for table in [
      "assistant_fetches_by_page_weekly",
      "assistant_fetches_weekly",
      "catalogue_daily",
      "chat_host_weekly",
      "consistency_weekly",
      "consumer_cohorts_weekly",
      "crawler_reads_weekly",
      "delivery_topics_daily",
      "dependence_weekly",
      "embedding_sites_weekly",
      "headline_families_weekly",
      "headline_weekly",
      "indicator_uses_weekly",
      "mcp_tool_calls_weekly",
      "int_surface_weeks_observed",
      "int_variable_topics",
      "public_repos_weekly",
      "reach_weekly",
      "regular_consumers_weekly",
      "regular_organisations_weekly",
      "requests_daily",
      "standing_pulls_weekly",
      "supply_coverage_daily",
      "topic_callers_weekly",
      "topic_demand_weekly",
      "topic_taxonomy",
      "trust_weekly",
      "website_log_users_weekly",
      "website_returning_weekly",
    ] : table => "${local.metrics_ref}.${table}"
  }
  metrics_view_descriptions = {
    metrics_headline_families_weekly     = "Grain: surface x iso_week x caller_class x audience x client_family. The headline counts split by client family on api and mcp. A consumer or address that used two families in a week is in both rows, so consumers, addresses, spec_uses, specs and indicators do not add up to metrics_headline_weekly; only deliveries add. consumers is null on pooled rows, whose distinct count is addresses. events names the dated_events in the week."
    metrics_headline_weekly              = "Grain: surface x iso_week x caller_class x audience. The headline counts in consumer-weeks and spec uses. consumers is null on pooled rows, whose distinct count is addresses; deliveries is null on studio and page. events names the dated_events in the week, such as hackathon. top_caller_uses is the spec uses of the row's largest consumer (its pool address on a pooled row) and top_caller_share is that over spec_uses; a surface's figure is max(top_caller_uses) / sum(spec_uses) over its rows outside one_campaign."
    metrics_regular_consumers_weekly     = "Grain: surface x iso_week x caller_class x audience. The mart holds one row per consumer and leaves pooled addresses out; counts are distinct on the consumer. A class and audience appear on a surface from the first week they hold any row there, and observed weeks after that with no regular read 0."
    metrics_dependence_weekly            = "Grain: surface x iso_week x caller_class x audience. The mart is already aggregated and leaves pooled addresses out; shares do not combine across rows. weeks_observed_of_last_4 and weeks_observed_of_last_8 give the observed weeks behind the regular counts; a shorter window can undercount."
    metrics_consumer_cohorts_weekly      = "Grain: surface x cohort_week x caller_class x audience. A cohort is the keys first active on a surface in that week; pooled addresses join none. The mart leaves a return null until the surface has observed the week it falls in. A rate is retained over cohort size within one caller class; in the address class a changed address counts as a departure and several people behind one address count as one, so read it beside the identified rows."
    metrics_standing_pulls_weekly        = "Grain: surface x iso_week x caller_class x audience. A standing pull is the same request made in 4 of the last 8 weeks; pooled addresses are left out."
    metrics_regular_organisations_weekly = "Grain: surface x iso_week x audience x organisation_group. Groups only. organisations counts domains for Named organisations alone; the other groups, including No label, hold account counts, and no count is suppressed for small cells."
    metrics_indicator_uses_weekly        = "Grain: surface x iso_week x kind x caller_class x audience. An indicator use is one consumer using one indicator in one week, whatever the client, so indicator_uses counts distinct (consumer, indicator) pairs. On pooled rows consumers is null and addresses counts the distinct pool addresses."
    metrics_delivery_topics_weekly       = "Grain: surface x iso_week x axis x topic_id. Dataset reads split across their spec's topics by weight, summed from days to complete weeks. Reads on surfaces with no observation mark (unknown, direct) are left out. Studio and MCP reads come from Studio turns and MCP call lines across the whole span (source backfill before the line records), so no read sits under unknown; Studio counts once per turn and dataset."
    metrics_chat_host_weekly             = "Grain: iso_week x host, a chat-host client family in user_agent_families. Calls count when served as a use. Chat-host calls reach DFO through the api and mcp surfaces, so api_observed and mcp_observed say which surfaces observed the week in full; a week with either false reads low. The mart has no row for a host-week with no calls."
    metrics_assistant_fetches_weekly     = "Grain: iso_week x agent_name x kind (page, api). Requests from agents that fetch for a person and name themselves. Read from website request logs, so a week counts when the website surface observed it."
    metrics_crawler_reads_weekly         = "Grain: iso_week x agent_name x kind (page, api, rsc). Requests from self-declared search and training crawlers, observed as the website."
    metrics_reach_weekly                 = "Grain: iso_week x kind (share, embed). Opens of shared or embedded artefacts by someone other than their creator. The host where an artefact was opened is aggregated away; hosts counts the distinct ones that opened at least once."
    metrics_embedding_sites_weekly       = "Grain: iso_week. Sites that embed DFO, the view holds no host names. A site counts in a week when it opened at least once."
    metrics_public_repos_weekly          = "Grain: iso_week. Public repositories that declare the SDK or name the MCP endpoint, from the weekly repository search."
    metrics_trust_weekly                 = "Grain: iso_week x slot_source x share_era. Replay-probe readings from complete runs only; run_date is the UTC date the week's replay run started. Derived cards are compared with their stored frame; dataset cards are reported as still current or moved."
    metrics_consistency_weekly           = "Grain: iso_week. Derived frames recomputed in a week, and how many of those seen the week before recompute to the same digest."
    metrics_requests_weekly              = "Grain: iso_week x service. Requests and server errors per Cloud Run service, summed from days to complete weeks. availability is the share of requests without a 5xx response; 4xx responses count as answered."
    metrics_supply_coverage_daily        = "Grain: day x coverage (curated, data_commons, missing, unknown). Target sources on the seeded list by how the day's catalogue holds them; unknown is a day whose build logged no provenance lists. Complete days only."
    metrics_catalogue_daily              = "Grain: day. The search catalogue live at each complete day's end. Indicators are variables."
    metrics_topic_demand_weekly          = "Grain: iso_week x axis x topic_id. Studio questions split across subjects by weight; unmet is the grader's judgement. The mart suppresses topic-weeks under 5 weighted turns. Weeks follow the studio surface's observation mark. no_data_turns and missing_feature_turns split unmet_turns by grade (N and F) and are null where it is null. staff_share is the share of turns from ONE Campaign staff accounts, a floor where turns name no consumer; unknown_caller_share is the share of turns that name none."
    metrics_website_returning_weekly     = "Grain: iso_week. Website people active (a search or a share) and returning, by account, consented browser id and ONE Campaign staff; a browser ever seen signed in counts as its account. Returning is active in 2 of the last 4, or 3 of the last 8, weeks, whether or not active this week."
    metrics_topic_callers_weekly         = "Grain: iso_week x surface x axis x topic_id. Distinct callers who pulled data on each topic, ONE Campaign staff and AI tools' shared servers apart; total_callers is the surface's distinct callers that week, so callers / total_callers is a share of callers. datasets_pulled splits caller-dataset pairs by topic weight, and shared_server_datasets does the same for the shared servers."
    metrics_mcp_tool_calls_weekly        = "Grain: iso_week x tool. Successful MCP tool calls from outside callers, with shared servers' calls and failed calls apart; polls for pending answers are not counted. Complete weeks only."
    metrics_website_log_users_weekly     = "Grain: iso_week. Website users from the website's request lines, cookies or not: distinct address keys with a search or a share, so two browsers on one address count once. staff_users holds the ONE Campaign staff the account lines identify. A later account line also marks earlier activity, so a week can hold staff before accounts_linked turns true; accounts_linked marks the weeks that start on or after the first day the website logged account lines, the first weeks linked in full. Observed weeks only."
    metrics_assistant_pages_weekly       = "Grain: iso_week x agent_name x route. Pages that assistants such as ChatGPT-User and Claude-User fetched for a person's question, by route template; files such as robots.txt are not pages."
    metrics_variable_topics              = "Grain: axis x topic_id. Today's catalogue variables by main subject and by finance kind, from int_variable_topics (labels that are not stale). Totals dip while a topics run re-asks changed variables."
  }
  metrics_views = {
    for name, description in local.metrics_view_descriptions : name => {
      source      = "metrics"
      description = description
      query       = templatefile("${path.module}/sql/reporting/${name}.sql", local.metrics_table_refs)
    }
  }

  reporting_views = {
    for name, view in local.reporting_views_from_sources : name => (
      var.analytics_dbt_schedule_enabled && contains(local.reporting_mart_views, name)
      ? merge(view, { query = templatefile("${path.module}/sql/reporting/${name}_analytics.sql", { table = "${var.project_id}.${local.reporting_analytics_dataset}.${name}" }) })
      : view
    )
  }

  # Each view as its template reads its sources, before
  # var.analytics_dbt_schedule_enabled moves the views in reporting_mart_views
  # to the analytics tables.
  reporting_views_from_sources = merge(local.metrics_views, {
    service_requests_daily = {
      source      = "logs"
      description = "Cloud Run requests per UTC day and service, with status counts and approximate latency quantiles."
      query       = templatefile("${path.module}/sql/reporting/service_requests_daily.sql", { requests_daily = "${local.reporting_log_ref}.requests_daily" })
    }
    service_routes_daily = {
      source      = "logs"
      description = "Cloud Run requests per UTC day, service, method and route, with ids in the route written :id."
      query       = templatefile("${path.module}/sql/reporting/service_routes_daily.sql", { routes_daily = "${local.reporting_log_ref}.routes_daily" })
    }
    service_errors_daily = {
      source      = "logs"
      description = "Cloud Run stdout and stderr entries at WARNING or above per UTC day, service or job, logger and severity. No message text."
      query       = templatefile("${path.module}/sql/reporting/service_errors_daily.sql", { errors_daily = "${local.reporting_log_ref}.errors_daily" })
    }
    mcp_daily = {
      source      = "mcp"
      description = "Combined MCP server tool calls, resource reads, resource lists and initializes per UTC day, caller kind, client, request and outcome, with an HLL++ sketch of the callers. No caller, trace id, URI or other text."
      query       = templatefile("${path.module}/sql/reporting/mcp_daily.sql", { mcp_daily = "${local.reporting_log_ref}.mcp_daily" })
    }
    website_requests_daily = {
      source      = "website_requests"
      description = "Website request lines per UTC day, route, kind (page, api, rsc, prefetch, or unparsed), bot verdict and status class, with an HLL++ sketch of the callers. No caller, host, user agent or path beyond the route."
      query       = templatefile("${path.module}/sql/reporting/website_requests_daily.sql", { website_requests_daily = "${local.reporting_log_ref}.website_requests_daily" })
    }
    website_page_views_daily = {
      source      = "website_pages"
      description = "Website page views per UTC day, as page requests answered 2xx from visitors the website did not judge to be bots and from bots. Days before the request log's first parsed day come from the rebuilt Cloud Run history."
      query = var.analytics_dbt_schedule_enabled ? templatefile("${path.module}/sql/reporting/website_page_views_daily_analytics.sql", {
        website_page_views_daily = "${local.reporting_log_ref}.website_page_views_daily"
        }) : templatefile("${path.module}/sql/reporting/website_page_views_daily.sql", {
        website_requests_daily = "${local.reporting_log_ref}.website_requests_daily"
        history                = "${local.web_history_ref}.website_page_history"
      })
    }
    deploys = {
      source      = "logs"
      description = "Each Cloud Run revision deployed while the logs source ran, timed at its first request."
      query       = templatefile("${path.module}/sql/reporting/deploys.sql", { deploys = "${local.reporting_log_ref}.deploys" })
    }
    product_events_daily = {
      source      = "website"
      description = "Website product events per UTC day, event name, page and signed-in state, with HLL++ sketches of visitors and signed-in users. Pages have their ids written :id."
      query = templatefile("${path.module}/sql/reporting/product_events_daily.sql", {
        events          = "${var.project_id}.website_export.event"
        normalise_route = "${var.project_id}.${google_bigquery_dataset.reporting.dataset_id}.${google_bigquery_routine.reporting_normalise_route.routine_id}"
      })
    }
    account_returns_daily = {
      source      = "website"
      description = "Signed-in website accounts per UTC day: HLL++ sketches of the accounts active that day and of those whose first signed-in event in the export falls on an earlier day. Merged over a window they count the accounts active in it and the accounts active on a day after their first signed-in event in the export. No id."
      query       = templatefile("${path.module}/sql/reporting/account_returns_daily.sql", { events = "${var.project_id}.website_export.event" })
    }
    accounts_daily = {
      source      = "accounts"
      description = "Website accounts created per UTC day and organisation: the email domain when it holds at least 3 accounts, Personal email for a webmail domain, and Other organisations otherwise. No address and no user id."
      query       = templatefile("${path.module}/sql/reporting/accounts_daily.sql", { accounts = "${var.project_id}.website_export.account_daily" })
    }
    ai_turns = {
      source      = "langfuse"
      description = "One row per AI assistant turn: start, latency, time to first token, generation and tool counts, tokens including cached input, cost, errors, and an HLL++ sketch of its session. No text and no id."
      query       = templatefile("${path.module}/sql/reporting/ai_turns.sql", { observations = local.langfuse_ref })
    }
    ai_observations_daily = {
      source      = "langfuse"
      description = "Langfuse observations per UTC day, type, name, model, trace name and level, with errors, latency quantiles, tokens including cached input, cost, and a KLL sketch of latency that merges across rows."
      query       = templatefile("${path.module}/sql/reporting/ai_observations_daily.sql", { observations = local.langfuse_ref })
    }
    ga4_daily = {
      source      = "ga4"
      description = "GA4 active users, sessions, page views and declined page views per day in the property's time zone, from the Data API history before the export's first day and the export from then on, with an HLL++ sketch of the active users on export days. Users and sessions count visitors who accepted analytics storage. Export days' page views include declined ones, and history days hold accepted ones with declined_page_views and users_sketch NULL."
      query = templatefile("${path.module}/sql/reporting/ga4_daily.sql", {
        events  = local.ga4_events_ref
        history = "${local.web_history_ref}.ga4_daily"
      })
    }
    ga4_pages_daily = {
      source      = "ga4"
      description = "GA4 page views, sessions and declined page views per day in the property's time zone and page path, split by consent as in ga4_daily. Sessions do not sum across pages."
      query = templatefile("${path.module}/sql/reporting/ga4_pages_daily.sql", {
        events  = local.ga4_events_ref
        history = "${local.web_history_ref}.ga4_pages_daily"
      })
    }
    ga4_user_ranges = {
      source      = "ga4"
      description = "GA4 Data API active, total and new users over each range the ga4-user-ranges workflow lists: since 2026-10-05, the last 7 and 28 days, and each ISO week and calendar month, all ending no later than yesterday in the property's time zone. Users count once per range, and only visitors who accepted analytics storage."
      query       = templatefile("${path.module}/sql/reporting/ga4_user_ranges.sql", { ranges = "${local.web_history_ref}.${google_bigquery_table.ga4_user_ranges.table_id}" })
    }
    search_console_daily = {
      source      = "search_console"
      description = "Search Console web-search clicks, impressions and sum_position for the property per Pacific Time day, from the API history before the bulk export's first day and the export from then on."
      query = templatefile("${path.module}/sql/reporting/search_console_daily.sql", {
        site_impressions = "${var.project_id}.${google_bigquery_dataset.searchconsole.dataset_id}.searchdata_site_impression"
        history          = "${local.web_history_ref}.search_console_daily"
      })
    }
    search_console_pages = {
      source      = "search_console"
      description = "Search Console web-search clicks, impressions and sum_position per Pacific Time day and page URL, without query strings or fragments."
      query = templatefile("${path.module}/sql/reporting/search_console_pages.sql", {
        url_impressions = "${var.project_id}.${google_bigquery_dataset.searchconsole.dataset_id}.searchdata_url_impression"
        history         = "${local.web_history_ref}.search_console_pages_daily"
      })
    }
    cloudflare_daily = {
      source      = "cloudflare"
      description = "Cloudflare page loads per UTC day: eyeball GET requests answered 200 with HTML on the website's hosts, from no verified bot and from verified bots, for the days scripts/load-cloudflare-history.sh loaded."
      query       = templatefile("${path.module}/sql/reporting/cloudflare_daily.sql", { history = "${local.web_history_ref}.cloudflare_daily" })
    }
    cloudflare_pages_daily = {
      source      = "cloudflare_pages"
      description = "Cloudflare page loads per UTC day for the prototypes app's paths under /prototypes, the only paths captured: eyeball GET requests answered 200 with HTML on the website's hosts, from no verified bot and from verified bots, for the days scripts/load-cloudflare-pages-history.sh loaded."
      query       = templatefile("${path.module}/sql/reporting/cloudflare_pages_daily.sql", { history = "${local.web_history_ref}.cloudflare_pages_daily" })
    }
    model_spend_daily = {
      source      = "billing"
      description = "Cloud Billing cost, credits and net cost per UTC day, DFO caller, service, SKU and currency. Billing keeps adding cost to a day for about a day after it ends, so only days before yesterday are kept."
      query = templatefile("${path.module}/sql/reporting/model_spend_daily.sql", {
        billing = "${var.project_id}.${var.billing_export_dataset}.gcp_billing_export_v1_*"
        callers = join(", ", [for id, caller in var.spend_callers : "('${id}', '${caller}')"])
      })
    }
  })

  reporting_views_enabled = {
    for name, view in local.reporting_views : name => view if contains(var.reporting_sources, view.source)
  }

  reporting_view_grants = {
    for grant in flatten([
      for name, view in local.reporting_views_enabled : [
        for dataset in local.reporting_source_datasets[view.source] : { view = name, dataset = dataset }
      ]
    ]) : "${grant.dataset}/${grant.view}" => grant
  }
}

# The route rule product_events_daily applies to pages, built from the same
# file as logs_daily.normalise_route, so pages and request routes normalise
# alike. It lives here because readers hold READER on dfo_reporting, which
# lets them run its routines, and no access to logs_daily.
resource "google_bigquery_routine" "reporting_normalise_route" {
  dataset_id      = google_bigquery_dataset.reporting.dataset_id
  routine_id      = "normalise_route"
  routine_type    = "SCALAR_FUNCTION"
  language        = "SQL"
  description     = "Route of a URL or path: the path with id, dcid, hash and number segments as :id. Same body as logs_daily.normalise_route."
  definition_body = file("${path.module}/sql/normalise_route.sql")
  return_type     = jsonencode({ typeKind = "STRING" })

  arguments {
    name      = "url"
    data_type = jsonencode({ typeKind = "STRING" })
  }
}

resource "google_bigquery_table" "reporting" {
  for_each = local.reporting_views_enabled

  dataset_id  = google_bigquery_dataset.reporting.dataset_id
  table_id    = each.key
  description = each.value.description

  # A view holds no data, so removing its group from var.reporting_sources
  # may delete it.
  deletion_protection = false

  view {
    use_legacy_sql = false
    query          = each.value.query
  }
}

# One authorised-view entry per view and source dataset. Each is a
# google_bigquery_dataset_access, the only kind of grant on these datasets
# (README), so applying one leaves every other entry in place.
resource "google_bigquery_dataset_access" "reporting_views" {
  for_each = local.reporting_view_grants

  dataset_id = each.value.dataset

  view {
    project_id = var.project_id
    dataset_id = google_bigquery_dataset.reporting.dataset_id
    table_id   = google_bigquery_table.reporting[each.value.view].table_id
  }
}
