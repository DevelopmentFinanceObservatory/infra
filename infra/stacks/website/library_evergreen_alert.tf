# Alerting on the Library's evergreen check. A Library publish or text edit
# holds the text to the evergreen rule with TypeSafe's Jev model, through
# TYPESAFE_API_KEY (main.tf). When the check cannot run, the route answers
# 503 `evergreen_check_unavailable` and logs one line at ERROR whose `message`
# is `library_evergreen_unavailable`, with a `cause` (such as missing_key,
# timeout, http or model) and TypeSafe's `status`. The rest of the site keeps
# serving, so this metric is the only alert that the Library cannot publish.
# Cloud Run parses the service's JSON log lines, so the fields land in
# jsonPayload.

resource "google_logging_metric" "library_evergreen_unavailable" {
  name    = "${local.website_name}-library-evergreen-unavailable"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${module.website_service.service_name}"
    resource.labels.location="${var.region}"
    jsonPayload.message="library_evergreen_unavailable"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# Waits out the log-based metric's propagation to Cloud Monitoring before the
# alert policy names it. The apis stack's graph_release.tf explains the 404
# a plain depends_on leaves open.
resource "time_sleep" "library_evergreen_metric_propagation" {
  depends_on = [google_logging_metric.library_evergreen_unavailable]
  triggers = {
    metrics = google_logging_metric.library_evergreen_unavailable.name
  }
  create_duration = "120s"
}

# Any one line opens the incident. Publishes come from a few Library admins,
# so each line is an admin who could not publish, and a key that is missing
# or rejected fails every publish until someone fixes it. A single timeout
# that a retry mends closes on its own after an hour.
resource "google_monitoring_alert_policy" "library_evergreen_unavailable" {
  project      = var.project_id
  display_name = "Library publishing closed on ${local.website_name}"
  combiner     = "OR"

  depends_on = [time_sleep.library_evergreen_metric_propagation]

  # ALIGN_SUM, since Cloud Logging writes a zero sample in the interval
  # beside each non-zero one, which ALIGN_COUNT would count as a failure.
  conditions {
    display_name = "library_evergreen_unavailable logged"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.library_evergreen_unavailable.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
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
      Library publishing is closed on ${module.website_service.service_name}. While this fires, every Library publish and text edit answers 503 `evergreen_check_unavailable`, because the check that the text is evergreen cannot run. The rest of the site serves as usual.

      Read the cause: `gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="${module.website_service.service_name}" AND jsonPayload.message="library_evergreen_unavailable"' --project=${var.project_id} --freshness=1d --limit=20`. Each line gives `cause` and TypeSafe's `status`.

      `missing_key`, or `http` with status 401 or 403, points at the key. The service reads the latest version of the `${data.google_secret_manager_secret.typesafe.secret_id}` secret as TYPESAFE_API_KEY when an instance starts, and the apis service reads the same secret. List the versions with `gcloud secrets versions list ${data.google_secret_manager_secret.typesafe.secret_id} --project=${var.project_id}`, and compare a version's length without printing the key with `gcloud secrets versions access <version> --secret=${data.google_secret_manager_secret.typesafe.secret_id} --project=${var.project_id} | wc -c`. Add a corrected version or disable the bad one, then roll the service onto a new revision so instances read it: `gcloud run services update ${module.website_service.service_name} --project=${var.project_id} --region=${var.region} --update-labels=rolled-at=$(date +%Y%m%d%H%M%S)`.

      `timeout`, `connection`, `http` with a 5xx or 429, or `model` points at TypeSafe itself. Publishing stays closed until TypeSafe answers, and nothing on this side reopens it. Check TypeSafe's service status, and follow the `cause` and `status` in the log lines above until they stop. The incident closes an hour after the last line.
    EOT
  }

  notification_channels = local.alert_notification_channels

  alert_strategy {
    auto_close = "3600s"
  }
}
