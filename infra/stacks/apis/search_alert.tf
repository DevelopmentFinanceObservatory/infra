# Alerting on search failures in the apis service: engine infrastructure
# errors in the service log, and 5xx answers on POST /api/search/resolve in
# Cloud Run's request log. A revision can pass its startup probe and take
# traffic while every search fails, and these log metrics are then the only
# alert. A Gemini key that Gemini rejects is one such case: every resolve logs
# an engine infrastructure error and answers 503.

# search.engine.app logs `Engine infrastructure error: <cause>` at ERROR for
# every EngineInfraError a search route raises, such as Gemini rejecting the
# key or the graph answering 500. Cloud Run parses the service's JSON log
# lines, so the logger name and message land in jsonPayload.
resource "google_logging_metric" "search_engine_infra_error" {
  name    = "${var.namespace}-search-engine-infra-error"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${module.apis_service.service_name}"
    resource.labels.location="${var.region}"
    severity=ERROR
    jsonPayload.logger="search.engine.app"
    jsonPayload.message=~"^Engine infrastructure error:"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# The request log also counts the 5xx answers that never reach the engine's
# error handler: a crash, a timeout at the Cloud Run front end, an instance
# that failed to start. The anchored path leaves out the other search routes.
resource "google_logging_metric" "search_resolve_5xx" {
  name    = "${var.namespace}-search-resolve-5xx"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${module.apis_service.service_name}"
    resource.labels.location="${var.region}"
    log_id("run.googleapis.com/requests")
    httpRequest.requestUrl=~"/api/search/resolve([?]|$)"
    httpRequest.status>=500
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# Waits out the log-based metrics' propagation to Cloud Monitoring before
# the alert policy names them; graph_release.tf explains the failure this avoids.
resource "time_sleep" "search_metric_propagation" {
  depends_on = [
    google_logging_metric.search_engine_infra_error,
    google_logging_metric.search_resolve_5xx,
  ]
  create_duration = "120s"
}

# Each condition sums its metric across the service's revisions over a rolling
# 5 minutes and opens at three or more, so a rollout that splits the failures
# between two revisions still counts them together. Search traffic is light
# and bursty: over the 14 days to 2026-10-24, prod served about 540 resolves
# a day. One or two failures in 5 minutes happened there 17 times outside
# outages and are left alone. Three or more happened only in outages: the
# graph answering 500 on /v2/resolve three times, and the rejected Gemini key,
# whose first 5 minutes held nine failed resolves. An outage therefore opens the incident with the
# first three searches that fail, inside 5 minutes while anyone is searching.
# An outage with no traffic fails no one and opens nothing until the next
# searches arrive.
resource "google_monitoring_alert_policy" "search_failing" {
  project      = var.project_id
  display_name = "Search failing on the apis service"
  combiner     = "OR"

  depends_on = [time_sleep.search_metric_propagation]

  conditions {
    display_name = "3 or more engine infrastructure errors in 5 minutes"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.search_engine_infra_error.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 2
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.service_name"]
      }
    }
  }

  conditions {
    display_name = "3 or more 5xx answers on /api/search/resolve in 5 minutes"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.search_resolve_5xx.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 2
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.service_name"]
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Searches on ${module.apis_service.service_name} are failing. Read the service's errors: in Logs Explorer, filter on `resource.labels.service_name="${module.apis_service.service_name}" severity>=ERROR` and read the cause after `Engine infrastructure error:`.

      `Gemini API error: 400 INVALID_ARGUMENT ... API key not valid`, 401 or 403 means Gemini rejects the key. The service reads the latest version of the `${data.google_secret_manager_secret.gemini.secret_id}` secret as GEMINI_API_KEY when an instance starts. Compare the version the failing revision started on with the one the previous revision ran on: `gcloud secrets versions list ${data.google_secret_manager_secret.gemini.secret_id} --project=${var.project_id}` shows when each was added, and `gcloud secrets versions access <version> --secret=${data.google_secret_manager_secret.gemini.secret_id} --project=${var.project_id} | wc -c` compares their lengths without printing the key. Add a corrected version or disable the bad one, then deploy a new revision so instances read it.

      A graph, SDMX or deadline cause points at that dependency instead.
    EOT
  }

  notification_channels = local.alert_notification_channels

  alert_strategy {
    auto_close = "3600s"
  }
}
