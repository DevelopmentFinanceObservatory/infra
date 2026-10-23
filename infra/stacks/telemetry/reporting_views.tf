# The views the team dashboard reads, in dfo_reporting. Each view's query is
# a template under sql/reporting, and tests/reporting_*.test.sh run each one
# over literal source rows. Each view reads one source group, and is created
# only once var.reporting_sources lists that group, since a view cannot name
# a table that does not exist yet. Readers of dfo_reporting get no access to
# the sources, so each view is authorised on every dataset it reads.
locals {
  # The datasets each source group's views read. website_export and
  # langfuse_export are created by the website and ai stacks, the GA4 export
  # dataset by the GA4 BigQuery link, and the billing export dataset by the
  # foundation stack.
  reporting_source_datasets = {
    logs           = [google_bigquery_dataset.logs_daily.dataset_id]
    website        = ["website_export"]
    accounts       = ["website_export"]
    langfuse       = ["langfuse_export"]
    ga4            = [var.ga4_export_dataset, google_bigquery_dataset.web_history.dataset_id]
    search_console = [google_bigquery_dataset.searchconsole.dataset_id, google_bigquery_dataset.web_history.dataset_id]
    billing        = [var.billing_export_dataset]
  }

  logs_daily_ref  = "${var.project_id}.${google_bigquery_dataset.logs_daily.dataset_id}"
  web_history_ref = "${var.project_id}.${google_bigquery_dataset.web_history.dataset_id}"
  langfuse_ref    = "${var.project_id}.langfuse_export.observations"
  # events_2* matches the daily events_YYYYMMDD tables and leaves out
  # events_intraday_* should streaming export ever be turned on, since those
  # repeat the day's events.
  ga4_events_ref = "${var.project_id}.${var.ga4_export_dataset}.events_2*"

  reporting_views = {
    service_requests_daily = {
      source      = "logs"
      description = "Cloud Run requests per UTC day and service, with status counts and approximate latency quantiles."
      query       = templatefile("${path.module}/sql/reporting/service_requests_daily.sql", { requests_daily = "${local.logs_daily_ref}.requests_daily" })
    }
    service_routes_daily = {
      source      = "logs"
      description = "Cloud Run requests per UTC day, service, method and route, with ids in the route written :id."
      query       = templatefile("${path.module}/sql/reporting/service_routes_daily.sql", { routes_daily = "${local.logs_daily_ref}.routes_daily" })
    }
    service_errors_daily = {
      source      = "logs"
      description = "Cloud Run stdout and stderr entries at WARNING or above per UTC day, service or job, logger and severity. No message text."
      query       = templatefile("${path.module}/sql/reporting/service_errors_daily.sql", { errors_daily = "${local.logs_daily_ref}.errors_daily" })
    }
    deploys = {
      source      = "logs"
      description = "Each Cloud Run revision deployed while the logs source ran, timed at its first request."
      query       = templatefile("${path.module}/sql/reporting/deploys.sql", { deploys = "${local.logs_daily_ref}.deploys" })
    }
    product_events_daily = {
      source      = "website"
      description = "Website product events per UTC day, event name, page and signed-in state, with HLL++ sketches of visitors and signed-in users. Pages have their ids written :id."
      query = templatefile("${path.module}/sql/reporting/product_events_daily.sql", {
        events          = "${var.project_id}.website_export.event"
        normalise_route = "${var.project_id}.${google_bigquery_dataset.reporting.dataset_id}.${google_bigquery_routine.reporting_normalise_route.routine_id}"
      })
    }
    accounts_daily = {
      source      = "accounts"
      description = "Website accounts created per UTC day and organisation: the email domain when it holds at least 3 accounts, Personal email for a webmail domain, and Other organisations otherwise. No address and no user id."
      query       = templatefile("${path.module}/sql/reporting/accounts_daily.sql", { accounts = "${var.project_id}.website_export.account_daily" })
    }
    ai_turns = {
      source      = "langfuse"
      description = "One row per AI assistant turn: start, latency, time to first token, generation and tool counts, tokens, cost, errors, and an HLL++ sketch of its session. No text and no id."
      query       = templatefile("${path.module}/sql/reporting/ai_turns.sql", { observations = local.langfuse_ref })
    }
    ai_observations_daily = {
      source      = "langfuse"
      description = "Langfuse observations per UTC day, type, name and model, with errors, latency quantiles, tokens, cost, and a KLL sketch of latency that merges across rows."
      query       = templatefile("${path.module}/sql/reporting/ai_observations_daily.sql", { observations = local.langfuse_ref })
    }
    ga4_daily = {
      source      = "ga4"
      description = "GA4 active users, sessions and page views per day in the property's time zone, from the Data API history before the export's first day and the export from then on."
      query = templatefile("${path.module}/sql/reporting/ga4_daily.sql", {
        events  = local.ga4_events_ref
        history = "${local.web_history_ref}.ga4_daily"
      })
    }
    ga4_pages_daily = {
      source      = "ga4"
      description = "GA4 page views and sessions per day in the property's time zone and page path. Sessions do not sum across pages."
      query = templatefile("${path.module}/sql/reporting/ga4_pages_daily.sql", {
        events  = local.ga4_events_ref
        history = "${local.web_history_ref}.ga4_pages_daily"
      })
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
    model_spend_daily = {
      source      = "billing"
      description = "Cloud Billing cost, credits and net cost per UTC day, DFO caller, service, SKU and currency. Billing keeps adding cost to a day for about a day after it ends, so only days before yesterday are kept."
      query = templatefile("${path.module}/sql/reporting/model_spend_daily.sql", {
        billing = "${var.project_id}.${var.billing_export_dataset}.gcp_billing_export_v1_*"
        callers = join(", ", [for id, caller in var.spend_callers : "('${id}', '${caller}')"])
      })
    }
  }

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
