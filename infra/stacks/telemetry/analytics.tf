# The datasets and identities of the DevelopmentFinanceObservatory/analytics
# repository, a dbt project that builds its models from the four source
# datasets below. The metric logic lives in that repository. This stack holds
# only the datasets dbt writes and the grants that let it read and write.
#
# Each dbt target writes one dataset: prod (the scheduled job's service
# account) writes analytics, ci (the CI service account) writes analytics_ci,
# and dev (a developer's own credentials) writes analytics_dev. The CI and
# dev datasets expire their tables, so a model that was renamed or dropped
# leaves nothing behind for long.
locals {
  analytics_datasets = {
    analytics = {
      description   = "Models built by the analytics repository's scheduled dbt run as ${var.namespace}-analytics-runner."
      expiration_ms = null
    }
    analytics_ci = {
      description   = "Models built by the analytics repository's CI as ${var.namespace}-analytics-ci. Tables expire after a day."
      expiration_ms = 24 * 60 * 60 * 1000
    }
    analytics_dev = {
      description   = "Models built by analytics developers with their own credentials. Tables expire after seven days."
      expiration_ms = 7 * 24 * 60 * 60 * 1000
    }
  }

  # The datasets the analytics repository's Python jobs write, each with the
  # one job account (analytics_job_accounts below) that holds WRITER on it.
  # The grader creates its own tables. Every other job's tables are declared
  # below. Every dataset exists whatever var.analytics_jobs_enabled says
  # (analytics_jobs.tf), since the analytics changes that write them need
  # them before the jobs run.
  analytics_job_datasets = {
    edge_export = {
      description = "Dataset reads Cloudflare's edge answered, loaded hourly from the edge logs bucket by the ${var.namespace}-analytics-edge Job as ${var.namespace}-analytics-edge."
      account     = "edge"
    }
    studio_grades = {
      description = "Grades of finished Studio turns, written daily by the ${var.namespace}-analytics-grade Job as ${var.namespace}-analytics-grader."
      account     = "grader"
    }
    repo_search = {
      description = "Public GitHub repositories that declare a DFO SDK or name the MCP endpoint, written weekly by the ${var.namespace}-analytics-repos Job as ${var.namespace}-analytics-repos."
      account     = "repos"
    }
    lighthouse = {
      description = "Throttled mobile Lighthouse measurements of the site's key pages from the PageSpeed Insights API, written weekly by the ${var.namespace}-analytics-lighthouse Job as ${var.namespace}-analytics-lighthouse."
      account     = "lighthouse"
    }
    replay_probe = {
      description = "Whether dfo-apis recomputes the frames behind a sample of share links to the same bytes, written weekly by the ${var.namespace}-analytics-replay Job as ${var.namespace}-analytics-replay."
      account     = "replay"
    }
    citation_probe = {
      description = "Answers of AI assistants to a fixed question set and whether they cite DFO, written monthly by the ${var.namespace}-analytics-citations Job as ${var.namespace}-analytics-citations."
      account     = "citations"
    }
  }

  # The datasets dbt/models/sources.yml in the analytics repository declares.
  # website_export and langfuse_export are created by the website and ai
  # stacks. dfo_logs holds request IPs and user agents, and both accounts and
  # every analytics developer below read it, as README "Logs" lists.
  analytics_source_datasets = [
    google_logging_linked_dataset.telemetry.link_id,
    "website_export",
    "langfuse_export",
    google_bigquery_dataset.logs_daily.dataset_id,
    google_bigquery_dataset.web_history.dataset_id,
    google_bigquery_dataset.analytics_job["edge_export"].dataset_id,
    google_bigquery_dataset.analytics_job["studio_grades"].dataset_id,
    google_bigquery_dataset.analytics_job["repo_search"].dataset_id,
    google_bigquery_dataset.analytics_job["lighthouse"].dataset_id,
    google_bigquery_dataset.analytics_job["replay_probe"].dataset_id,
    google_bigquery_dataset.analytics_job["citation_probe"].dataset_id,
  ]

  # The service accounts, each with the one dataset it writes. The
  # runner writes only analytics, so a model the analytics repository places in
  # another dataset with +schema needs a WRITER grant on that dataset here
  # first.
  analytics_accounts = {
    ci = {
      display_name = "${var.namespace} analytics CI"
      description  = "Runs the analytics repository's dbt build in CI: reads the analytics sources, writes analytics_ci."
      dataset      = "analytics_ci"
    }
    runner = {
      display_name = "${var.namespace} analytics dbt run"
      description  = "Runs the analytics repository's scheduled dbt build: reads the analytics sources, writes analytics."
      dataset      = "analytics"
    }
  }

  analytics_account_source_grants = {
    for pair in setproduct(keys(local.analytics_accounts), local.analytics_source_datasets) :
    "${pair[0]} ${pair[1]}" => { account = pair[0], dataset = pair[1] }
  }

  # The developers, from the principals secret's analytics_developers object
  # (main.tf), split by member kind as reporting.tf splits the readers. Each
  # grant is keyed by the developer's label, and the member stays sensitive.
  analytics_developer_principals = {
    for label in nonsensitive(keys(local.principals.analytics_developers)) : label => {
      member  = local.principals.analytics_developers[label]
      kind    = split(":", local.principals.analytics_developers[label])[0]
      address = split(":", local.principals.analytics_developers[label])[1]
    }
  }

  analytics_developer_source_grants = {
    for pair in setproduct(keys(local.analytics_developer_principals), local.analytics_source_datasets) :
    "${pair[0]} ${pair[1]}" => { developer = pair[0], dataset = pair[1] }
  }
}

resource "google_bigquery_dataset" "analytics" {
  for_each = local.analytics_datasets

  dataset_id                  = each.key
  location                    = local.bigquery_location
  description                 = each.value.description
  default_table_expiration_ms = each.value.expiration_ms

  # Every grant on this dataset is a google_bigquery_dataset_access. An access
  # block here would be authoritative and remove them on the next apply.

  depends_on = [google_project_service.apis]
}

# The service accounts hold no keys. CI reaches its account through Workload
# Identity Federation (analytics_ci_wif below), and the runner is the identity
# of the dbt Job in analytics_jobs.tf.
resource "google_service_account" "analytics" {
  for_each = local.analytics_accounts

  account_id   = "${var.namespace}-analytics-${each.key}"
  display_name = each.value.display_name
  description  = each.value.description
}

resource "google_project_iam_member" "analytics_job_user" {
  for_each = local.analytics_accounts

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.analytics[each.key].member
}

resource "google_bigquery_dataset_access" "analytics_writer" {
  for_each = local.analytics_accounts

  dataset_id    = google_bigquery_dataset.analytics[each.value.dataset].dataset_id
  role          = "WRITER"
  user_by_email = google_service_account.analytics[each.key].email
}

# READER on dfo_logs is all a query of the linked dataset needs, as for
# dfo-prod-logs-daily (logs_daily.tf).
resource "google_bigquery_dataset_access" "analytics_source_reader" {
  for_each = local.analytics_account_source_grants

  dataset_id    = each.value.dataset
  role          = "READER"
  user_by_email = google_service_account.analytics[each.value.account].email
}

# Developers build in analytics_dev with their own credentials, so each gets
# the same reads as the service accounts and writes only there. Their
# roles/bigquery.jobUser is people_job_user in main.tf, shared with the
# readers. analytics_dev is one dataset for every developer, so the last build
# of a model replaces anyone else's.
resource "google_bigquery_dataset_access" "analytics_developers_writer" {
  for_each = local.analytics_developer_principals

  dataset_id     = google_bigquery_dataset.analytics["analytics_dev"].dataset_id
  role           = "WRITER"
  group_by_email = each.value.kind == "group" ? each.value.address : null
  user_by_email  = each.value.kind == "user" ? each.value.address : null
}

resource "google_bigquery_dataset_access" "analytics_developers_source_reader" {
  for_each = local.analytics_developer_source_grants

  dataset_id     = each.value.dataset
  role           = "READER"
  group_by_email = local.analytics_developer_principals[each.value.developer].kind == "group" ? local.analytics_developer_principals[each.value.developer].address : null
  user_by_email  = local.analytics_developer_principals[each.value.developer].kind == "user" ? local.analytics_developer_principals[each.value.developer].address : null
}

resource "google_bigquery_dataset" "analytics_job" {
  for_each = local.analytics_job_datasets

  dataset_id  = each.key
  location    = local.bigquery_location
  description = each.value.description

  # Every grant on this dataset is a google_bigquery_dataset_access, as on the
  # dbt datasets above.

  depends_on = [google_project_service.apis]
}

# The three tables the edge extract writes (dfo_analytics.extract.edge in the
# analytics repository), declared here so they exist before the first dbt
# build, whose sources name them, whatever var.analytics_jobs_enabled says.
# The extract creates a table only when absent, and refuses to run on an
# existing table whose columns differ from its own in name, type, mode or
# order, so each schema copies DELIVERIES_SCHEMA, LOADED_OBJECTS_SCHEMA and
# RUNS_SCHEMA, and the partitioning and clustering copy _ensure_tables.
# deletion_protection keeps its default of true, as on the stack's other data
# tables, since no other table holds these rows.
locals {
  analytics_edge_tables = {
    deliveries = {
      description     = "Dataset reads Cloudflare's edge answered, one row per ray and start time, loaded hourly from the edge logs bucket by the ${var.namespace}-analytics-edge Job. Two overlapping runs can insert a ray twice."
      partition_field = "edge_started_at"
      clustering      = ["spec_id"]
      schema = [
        { name = "ray_id", type = "STRING", mode = "REQUIRED" },
        { name = "edge_started_at", type = "TIMESTAMP", mode = "REQUIRED" },
        { name = "day", type = "DATE", mode = "REQUIRED" },
        { name = "method", type = "STRING", mode = "REQUIRED" },
        { name = "host", type = "STRING", mode = "NULLABLE" },
        { name = "path_kind", type = "STRING", mode = "REQUIRED" },
        { name = "spec_id", type = "STRING", mode = "NULLABLE" },
        { name = "content_version", type = "STRING", mode = "NULLABLE" },
        { name = "file_digest", type = "STRING", mode = "NULLABLE" },
        { name = "caller", type = "STRING", mode = "NULLABLE" },
        { name = "referer_host", type = "STRING", mode = "NULLABLE" },
        { name = "origin_host", type = "STRING", mode = "NULLABLE" },
        { name = "client", type = "STRING", mode = "NULLABLE" },
        { name = "user_agent", type = "STRING", mode = "NULLABLE" },
        { name = "country", type = "STRING", mode = "NULLABLE" },
        { name = "cache_status", type = "STRING", mode = "NULLABLE" },
        { name = "edge_status", type = "INTEGER", mode = "NULLABLE" },
        { name = "edge_bytes", type = "INTEGER", mode = "NULLABLE" },
        { name = "origin_status", type = "INTEGER", mode = "NULLABLE" },
        { name = "served_by", type = "STRING", mode = "REQUIRED" },
        { name = "source_object", type = "STRING", mode = "REQUIRED" },
        { name = "loaded_at", type = "TIMESTAMP", mode = "REQUIRED" },
      ]
    }
    loaded_objects = {
      description     = "Each edge log object the ${var.namespace}-analytics-edge Job recorded, with its generation, row count and status (loaded, rejected or unreadable)."
      partition_field = "loaded_at"
      clustering      = null
      schema = [
        { name = "object_name", type = "STRING", mode = "REQUIRED" },
        { name = "generation", type = "INTEGER", mode = "REQUIRED" },
        { name = "row_count", type = "INTEGER", mode = "REQUIRED" },
        { name = "loaded_at", type = "TIMESTAMP", mode = "REQUIRED" },
        { name = "status", type = "STRING", mode = "REQUIRED" },
      ]
    }
    runs = {
      description     = "Each ${var.namespace}-analytics-edge Job run, with the objects it recorded, the rows it inserted and whether it succeeded."
      partition_field = null
      clustering      = null
      schema = [
        { name = "run_id", type = "STRING", mode = "REQUIRED" },
        { name = "started_at", type = "TIMESTAMP", mode = "REQUIRED" },
        { name = "ended_at", type = "TIMESTAMP", mode = "REQUIRED" },
        { name = "objects", type = "INTEGER", mode = "REQUIRED" },
        { name = "row_count", type = "INTEGER", mode = "REQUIRED" },
        { name = "status", type = "STRING", mode = "REQUIRED" },
      ]
    }
  }
}

resource "google_bigquery_table" "analytics_edge" {
  for_each = local.analytics_edge_tables

  dataset_id  = google_bigquery_dataset.analytics_job["edge_export"].dataset_id
  table_id    = each.key
  description = each.value.description
  schema      = jsonencode(each.value.schema)
  clustering  = each.value.clustering

  dynamic "time_partitioning" {
    for_each = each.value.partition_field == null ? [] : [each.value.partition_field]
    content {
      type  = "DAY"
      field = time_partitioning.value
    }
  }
}

# The tables of the four probe jobs, declared here for the reason the edge
# tables are: the first dbt build reads them as sources, and the citations
# job refuses to run on a missing table. Each schema copies its job's schema
# constant in the analytics repository column for column and in order, with
# BigQuery's legacy type names (INTEGER, FLOAT, BOOLEAN) for the jobs' INT64,
# FLOAT64 and BOOL. A job creates a table only when it is absent and appends
# with its own schema, which a load job refuses where a mode differs, and the
# replay job refuses to run on a table whose types or modes differ, so a
# schema change in the analytics repository needs the same change here first.
# Each table is day-partitioned on its run time column, as the job's own
# TimePartitioning is, and none is clustered. deletion_protection keeps its
# default of true, as on the edge tables.
#
#   repo_search.matches, runs       dfo_analytics/repos/job.py SCHEMA, RUNS_SCHEMA
#   lighthouse.results, runs        dfo_analytics/lighthouse/job.py RESULTS_SCHEMA, RUNS_SCHEMA
#   replay_probe.slot_results       dfo_analytics/replay/job.py SLOT_RESULTS_SCHEMA
#   citation_probe.answers, runs    dfo_analytics/citations/job.py ANSWERS_SCHEMA, RUNS_SCHEMA
locals {
  analytics_probe_tables = {
    "repo_search matches" = {
      description     = "One row per query and public repository the ${var.namespace}-analytics-repos Job matched, with the repository's stars, push time and fork and archive flags."
      partition_field = "run_at"
      schema = [
        { name = "run_id", type = "STRING", mode = "REQUIRED" },
        { name = "run_at", type = "TIMESTAMP", mode = "REQUIRED" },
        { name = "query_id", type = "STRING", mode = "REQUIRED" },
        { name = "query_kind", type = "STRING", mode = "REQUIRED" },
        { name = "query_text", type = "STRING", mode = "REQUIRED" },
        { name = "total_count", type = "INTEGER", mode = "REQUIRED" },
        { name = "capped", type = "BOOLEAN", mode = "REQUIRED" },
        { name = "repo_full_name", type = "STRING", mode = "REQUIRED" },
        { name = "owner_login", type = "STRING", mode = "REQUIRED" },
        { name = "owner_type", type = "STRING", mode = "REQUIRED" },
        { name = "path", type = "STRING", mode = "REQUIRED" },
        { name = "stars", type = "INTEGER", mode = "REQUIRED" },
        { name = "pushed_at", type = "TIMESTAMP", mode = "NULLABLE" },
        { name = "archived", type = "BOOLEAN", mode = "REQUIRED" },
        { name = "fork", type = "BOOLEAN", mode = "REQUIRED" },
      ]
    }
    "repo_search runs" = {
      description     = "One row per query of each ${var.namespace}-analytics-repos run, with GitHub's total count, the repositories kept, and whether the query was capped, incomplete or failed."
      partition_field = "run_at"
      schema = [
        { name = "run_id", type = "STRING", mode = "REQUIRED" },
        { name = "run_at", type = "TIMESTAMP", mode = "REQUIRED" },
        { name = "query_id", type = "STRING", mode = "REQUIRED" },
        { name = "query_kind", type = "STRING", mode = "REQUIRED" },
        { name = "total_count", type = "INTEGER", mode = "REQUIRED" },
        { name = "kept_count", type = "INTEGER", mode = "REQUIRED" },
        { name = "capped", type = "BOOLEAN", mode = "REQUIRED" },
        { name = "incomplete", type = "BOOLEAN", mode = "REQUIRED" },
        { name = "failed", type = "BOOLEAN", mode = "REQUIRED" },
        { name = "error", type = "STRING", mode = "NULLABLE" },
      ]
    }
    "lighthouse results" = {
      description     = "One row per URL and attempt of the ${var.namespace}-analytics-lighthouse Job, with the Lighthouse metrics PageSpeed Insights returned or the attempt's error."
      partition_field = "run_at"
      schema = [
        { name = "run_id", type = "STRING", mode = "REQUIRED" },
        { name = "run_at", type = "TIMESTAMP", mode = "REQUIRED" },
        { name = "url", type = "STRING", mode = "REQUIRED" },
        { name = "attempt", type = "INTEGER", mode = "REQUIRED" },
        { name = "status", type = "STRING", mode = "REQUIRED" },
        { name = "error", type = "STRING", mode = "NULLABLE" },
        { name = "lighthouse_version", type = "STRING", mode = "NULLABLE" },
        { name = "performance_score", type = "FLOAT", mode = "NULLABLE" },
        { name = "fcp_ms", type = "FLOAT", mode = "NULLABLE" },
        { name = "lcp_ms", type = "FLOAT", mode = "NULLABLE" },
        { name = "tbt_ms", type = "FLOAT", mode = "NULLABLE" },
        { name = "cls", type = "FLOAT", mode = "NULLABLE" },
        { name = "speed_index_ms", type = "FLOAT", mode = "NULLABLE" },
        { name = "total_byte_weight", type = "INTEGER", mode = "NULLABLE" },
        { name = "final_url", type = "STRING", mode = "NULLABLE" },
        { name = "fetch_time", type = "TIMESTAMP", mode = "NULLABLE" },
      ]
    }
    "lighthouse runs" = {
      description     = "One row per ${var.namespace}-analytics-lighthouse run, with its URL and attempt counts and the URLs that had no successful attempt."
      partition_field = "run_at"
      schema = [
        { name = "run_id", type = "STRING", mode = "REQUIRED" },
        { name = "run_at", type = "TIMESTAMP", mode = "REQUIRED" },
        { name = "urls", type = "INTEGER", mode = "REQUIRED" },
        { name = "attempts", type = "INTEGER", mode = "REQUIRED" },
        { name = "failed_attempts", type = "INTEGER", mode = "REQUIRED" },
        { name = "failed_urls", type = "STRING", mode = "REPEATED" },
      ]
    }
    "replay_probe slot_results" = {
      description     = "One row per card of a share the ${var.namespace}-analytics-replay Job sampled, or per share it could not read, with the outcome of recomputing or re-reading the card's frame. A share is named by share_digest, the HMAC of its id."
      partition_field = "run_started_at"
      schema = [
        { name = "run_id", type = "STRING", mode = "REQUIRED" },
        { name = "run_started_at", type = "TIMESTAMP", mode = "REQUIRED" },
        { name = "probe_version", type = "STRING", mode = "REQUIRED" },
        { name = "share_digest", type = "STRING", mode = "REQUIRED" },
        { name = "share_kind", type = "STRING", mode = "REQUIRED" },
        { name = "share_mode", type = "STRING", mode = "REQUIRED" },
        { name = "share_created_at", type = "TIMESTAMP", mode = "REQUIRED" },
        { name = "age_band", type = "STRING", mode = "REQUIRED" },
        { name = "slot_source", type = "STRING", mode = "NULLABLE" },
        { name = "slot", type = "INTEGER", mode = "NULLABLE" },
        { name = "frame_kind", type = "STRING", mode = "NULLABLE" },
        { name = "frame_spec_id", type = "STRING", mode = "NULLABLE" },
        { name = "frame_content_version", type = "STRING", mode = "NULLABLE" },
        { name = "stored_content_version", type = "STRING", mode = "NULLABLE" },
        { name = "replayed_content_version", type = "STRING", mode = "NULLABLE" },
        { name = "outcome", type = "STRING", mode = "REQUIRED" },
        { name = "detail_code", type = "STRING", mode = "NULLABLE" },
        { name = "http_status", type = "INTEGER", mode = "NULLABLE" },
        { name = "latency_ms", type = "INTEGER", mode = "NULLABLE" },
        { name = "execution_identity", type = "STRING", mode = "NULLABLE" },
        { name = "stored_execution_identity", type = "STRING", mode = "NULLABLE" },
        { name = "refusal_code", type = "STRING", mode = "NULLABLE" },
        { name = "refusal_reason", type = "STRING", mode = "NULLABLE" },
        { name = "head_freshness", type = "STRING", mode = "NULLABLE" },
        { name = "head_served_from", type = "STRING", mode = "NULLABLE" },
        { name = "head_confirmed_at", type = "TIMESTAMP", mode = "NULLABLE" },
      ]
    }
    "citation_probe answers" = {
      description     = "One row per answer an AI assistant gave the ${var.namespace}-analytics-citations Job, with the URLs it cites, whether it cites or names DFO, and its text."
      partition_field = "run_at"
      schema = [
        { name = "run_id", type = "STRING", mode = "REQUIRED" },
        { name = "run_at", type = "TIMESTAMP", mode = "REQUIRED" },
        { name = "provider", type = "STRING", mode = "REQUIRED" },
        { name = "model", type = "STRING", mode = "REQUIRED" },
        { name = "question_id", type = "STRING", mode = "REQUIRED" },
        { name = "question_text", type = "STRING", mode = "REQUIRED" },
        { name = "attempt", type = "INTEGER", mode = "REQUIRED" },
        { name = "answered_at", type = "TIMESTAMP", mode = "REQUIRED" },
        { name = "cited_urls", type = "STRING", mode = "REPEATED" },
        { name = "source_urls", type = "STRING", mode = "REPEATED" },
        { name = "cites_dfo", type = "BOOLEAN", mode = "REQUIRED" },
        { name = "mentions_dfo", type = "BOOLEAN", mode = "REQUIRED" },
        { name = "answer_chars", type = "INTEGER", mode = "REQUIRED" },
        { name = "answer_text", type = "STRING", mode = "REQUIRED" },
        { name = "input_tokens", type = "INTEGER", mode = "NULLABLE" },
        { name = "output_tokens", type = "INTEGER", mode = "NULLABLE" },
        { name = "web_searches", type = "INTEGER", mode = "NULLABLE" },
      ]
    }
    "citation_probe runs" = {
      description     = "One row per provider and question of each ${var.namespace}-analytics-citations run, with the asks made, answered and failed, the last error, and whether the provider was skipped."
      partition_field = "run_at"
      schema = [
        { name = "run_id", type = "STRING", mode = "REQUIRED" },
        { name = "run_at", type = "TIMESTAMP", mode = "REQUIRED" },
        { name = "provider", type = "STRING", mode = "REQUIRED" },
        { name = "model", type = "STRING", mode = "REQUIRED" },
        { name = "question_id", type = "STRING", mode = "REQUIRED" },
        { name = "attempts", type = "INTEGER", mode = "REQUIRED" },
        { name = "answered", type = "INTEGER", mode = "REQUIRED" },
        { name = "failed", type = "INTEGER", mode = "REQUIRED" },
        { name = "skipped", type = "BOOLEAN", mode = "REQUIRED" },
        { name = "error", type = "STRING", mode = "NULLABLE" },
        { name = "started_at", type = "TIMESTAMP", mode = "REQUIRED" },
        { name = "finished_at", type = "TIMESTAMP", mode = "REQUIRED" },
      ]
    }
  }
}

resource "google_bigquery_table" "analytics_probe" {
  for_each = local.analytics_probe_tables

  dataset_id  = google_bigquery_dataset.analytics_job[split(" ", each.key)[0]].dataset_id
  table_id    = split(" ", each.key)[1]
  description = each.value.description
  schema      = jsonencode(each.value.schema)

  time_partitioning {
    type  = "DAY"
    field = each.value.partition_field
  }
}

# One account per Python job, each writing its own dataset and nothing else.
# They exist whatever var.analytics_jobs_enabled says, so the dataset grants
# are in place before a job first runs. What only a running job needs (the
# edge logs bucket, the secrets) is granted in analytics_jobs.tf behind the
# flag. The grader also reads langfuse_export, the turns it grades. The four
# probe accounts read no other dataset.
locals {
  analytics_job_accounts = {
    edge = {
      display_name = "${var.namespace} analytics edge extract"
      description  = "Runs the analytics repository's edge delivery extract: reads the edge logs bucket, writes edge_export."
      dataset      = "edge_export"
      readers      = []
    }
    grader = {
      display_name = "${var.namespace} analytics Studio turn grader"
      description  = "Runs the analytics repository's Studio turn grader: reads langfuse_export, writes studio_grades."
      dataset      = "studio_grades"
      readers      = ["langfuse_export"]
    }
    repos = {
      display_name = "${var.namespace} analytics public repository search"
      description  = "Runs the analytics repository's public GitHub repository search: calls the GitHub API, writes repo_search."
      dataset      = "repo_search"
      readers      = []
    }
    lighthouse = {
      display_name = "${var.namespace} analytics Lighthouse probe"
      description  = "Runs the analytics repository's Lighthouse probe: calls the PageSpeed Insights API, writes lighthouse."
      dataset      = "lighthouse"
      readers      = []
    }
    replay = {
      display_name = "${var.namespace} analytics replay probe"
      description  = "Runs the analytics repository's replay probe: calls the apis service's share sample and verify routes, writes replay_probe."
      dataset      = "replay_probe"
      readers      = []
    }
    citations = {
      display_name = "${var.namespace} analytics citation probe"
      description  = "Runs the analytics repository's AI assistant citation probe: calls the Anthropic, OpenAI and Perplexity APIs, writes citation_probe."
      dataset      = "citation_probe"
      readers      = []
    }
  }

  analytics_job_account_reader_grants = merge([
    for account, spec in local.analytics_job_accounts : {
      for dataset in spec.readers : "${account} ${dataset}" => { account = account, dataset = dataset }
    }
  ]...)
}

resource "google_service_account" "analytics_job" {
  for_each = local.analytics_job_accounts

  account_id   = "${var.namespace}-analytics-${each.key}"
  display_name = each.value.display_name
  description  = each.value.description
}

resource "google_project_iam_member" "analytics_job_job_user" {
  for_each = local.analytics_job_accounts

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.analytics_job[each.key].member
}

resource "google_bigquery_dataset_access" "analytics_job_writer" {
  for_each = local.analytics_job_accounts

  dataset_id    = google_bigquery_dataset.analytics_job[each.value.dataset].dataset_id
  role          = "WRITER"
  user_by_email = google_service_account.analytics_job[each.key].email
}

resource "google_bigquery_dataset_access" "analytics_job_reader" {
  for_each = local.analytics_job_account_reader_grants

  dataset_id    = each.value.dataset
  role          = "READER"
  user_by_email = google_service_account.analytics_job[each.value.account].email
}

# The grader's own Gemini API key, one key per caller as for the ai and apis
# stacks. Terraform declares the secret and holds no version: a project owner
# adds the key by hand before var.analytics_jobs_enabled is switched on, since
# the grade Job reads its latest version (README "Analytics jobs").
resource "google_secret_manager_secret" "analytics_grader_gemini" {
  secret_id = "${var.namespace}-analytics-grader-gemini-api-key"

  replication {
    auto {}
  }
}

# The probe jobs' third-party API keys, declared as the grader's Gemini key
# is: no version, a project owner adds each key by hand before
# var.analytics_jobs_enabled is switched on, and the Job reads its latest
# version. Each key belongs to one Job, whose account alone may read it
# (analytics_jobs.tf).
locals {
  analytics_probe_secrets = {
    repos_github_token           = "${var.namespace}-analytics-repos-github-token"
    lighthouse_psi_api_key       = "${var.namespace}-analytics-lighthouse-psi-api-key"
    citations_anthropic_api_key  = "${var.namespace}-analytics-citations-anthropic-api-key"
    citations_openai_api_key     = "${var.namespace}-analytics-citations-openai-api-key"
    citations_perplexity_api_key = "${var.namespace}-analytics-citations-perplexity-api-key"
  }
}

resource "google_secret_manager_secret" "analytics_probe" {
  for_each = local.analytics_probe_secrets

  secret_id = each.value

  replication {
    auto {}
  }
}

# Copied from ../foundation's `pool_id` default and its
# `workload_identity_pool_id` output, as infra/dfo-dev/apis/eval_reader.tf does.
variable "github_wif_pool_id" {
  description = "Short workload_identity_pool_id of the shared GitHub Actions WIF pool. Copied from the `foundation` stack's `workload_identity_pool_id` output."
  type        = string
  default     = "github-pool"
}

# Copied from ../foundation's `github_repositories["analytics"].id`. The pool's
# attribute condition admits only the ids in that map, so a value here that
# disagrees with it binds a member no token can match. Null leaves CI with no
# binding, until both stacks carry its id (README "Analytics repo").
variable "analytics_repository_id" {
  description = "Immutable numeric GitHub id of DevelopmentFinanceObservatory/analytics (GET /repos/DevelopmentFinanceObservatory/analytics -> id). Copied from the `foundation` stack's `github_repositories` variable. Null makes no WIF binding for the CI account."
  type        = string
  default     = null

  validation {
    condition     = var.analytics_repository_id == null || can(regex("^[0-9]+$", var.analytics_repository_id))
    error_message = "analytics_repository_id must be the repository's numeric GitHub id, or null."
  }
}

# Only a run on the analytics repository's main branch may impersonate the CI
# account. The account reads `dfo_logs`, request IPs and user agents included,
# so a pull request or a feature branch must not mint a token for it. The
# repository's dbt-build job queries BigQuery only on pushes to main. The member
# keys on `attribute.repo_ref`, which the pool's mapping composes from the
# repository id and the ref, for the reason ../foundation/main.tf gives for
# composing from ids.
resource "google_service_account_iam_member" "analytics_ci_wif" {
  count = var.analytics_repository_id == null ? 0 : 1

  service_account_id = google_service_account.analytics["ci"].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.github_wif_pool_id}/attribute.repo_ref/${var.analytics_repository_id}:refs/heads/main"

  lifecycle {
    # member identifies the binding, so a new repository id replaces it.
    # Creating the new member first keeps CI authenticating through the swap.
    create_before_destroy = true
  }
}

output "analytics_ci_service_account_email" {
  description = "Email of dfo-prod-analytics-ci, for the analytics repository's GCP_CI_SERVICE_ACCOUNT variable. GCP_WIF_PROVIDER takes the `foundation` stack's `workload_identity_provider` output."
  value       = google_service_account.analytics["ci"].email
}

# The analytics repository's job images. Its deploy workflow pushes one image
# per commit on main, tagged with the commit sha, and only
# dfo-prod-analytics-deployer may write here. The project's Artifact Registry
# API is enabled by the foundation stack. The cleanup policy matches
# ../foundation's `datacommons` repository: a keep rule wins over a delete rule,
# so the ten newest images survive for rollback whatever their age.
resource "google_artifact_registry_repository" "analytics" {
  location      = var.region
  repository_id = "analytics"
  format        = "DOCKER"
  description   = "Job images of the analytics repository, writable by ${var.namespace}-analytics-deployer only"

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-stale"
    action = "DELETE"
    condition {
      older_than = "2592000s"
      tag_state  = "TAGGED"
    }
  }
}

resource "google_service_account" "analytics_deployer" {
  account_id   = "${var.namespace}-analytics-deployer"
  display_name = "${var.namespace} analytics image deployer"
  description  = "Pushes the analytics repository's job images from its main branch and moves the analytics Jobs to each one. Writes the analytics Artifact Registry repository and those Jobs and nothing else."
}

resource "google_artifact_registry_repository_iam_member" "analytics_deployer_writer" {
  project    = google_artifact_registry_repository.analytics.project
  location   = google_artifact_registry_repository.analytics.location
  repository = google_artifact_registry_repository.analytics.repository_id
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.analytics_deployer.member
}

# The GitHub Environment and git ref the deployer's binding admits. The
# analytics repository's deploy workflow declares this Environment on its push
# from main, and the Environment's deployment branch policy there admits main
# alone.
locals {
  analytics_deploy_environment = "production"
  analytics_deploy_ref         = "refs/heads/main"
}

# Only a job on main that declares the production Environment may impersonate
# the deployer, as for dfo-ai-deployer (../foundation's `ai_deployer`): the
# member keys on `attribute.repo_env_ref`, which the pool maps to
# <repository_id>:<environment>:<ref>. A pull request run carries neither
# claim, so it cannot push an image the scheduled jobs would then run. Null
# analytics_repository_id makes no binding.
resource "google_service_account_iam_member" "analytics_deployer_wif" {
  count = var.analytics_repository_id == null ? 0 : 1

  service_account_id = google_service_account.analytics_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.github_wif_pool_id}/attribute.repo_env_ref/${var.analytics_repository_id}:${local.analytics_deploy_environment}:${local.analytics_deploy_ref}"

  lifecycle {
    # member identifies the binding, so a new repository id replaces it.
    # Creating the new member first keeps deploys authenticating through the
    # swap.
    create_before_destroy = true
  }
}

output "analytics_deployer_service_account_email" {
  description = "Email of dfo-prod-analytics-deployer, for the analytics repository's GCP_DEPLOY_SERVICE_ACCOUNT variable."
  value       = google_service_account.analytics_deployer.email
}

output "analytics_image_repository" {
  description = "Docker path of the analytics Artifact Registry repository, which the analytics repository's deploy workflow pushes to."
  value       = "${google_artifact_registry_repository.analytics.location}-docker.pkg.dev/${google_artifact_registry_repository.analytics.project}/${google_artifact_registry_repository.analytics.repository_id}"
}
