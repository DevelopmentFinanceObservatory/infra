# Failure alerts for the two hourly export Jobs that fill the datasets the
# analytics dbt build reads. The Jobs belong to the website and ai stacks, and
# this stack names them by their fixed names.

# An email channel carries one address, so each recipient in the principals
# secret's alerts object (main.tf) gets a channel, keyed and named by its
# label.
resource "google_monitoring_notification_channel" "alert_email" {
  for_each = toset(nonsensitive(keys(local.principals.alerts)))

  project      = var.project_id
  display_name = "Telemetry pipeline alerts: ${each.key}"
  type         = "email"
  labels = {
    email_address = local.principals.alerts[each.key]
  }
}

locals {
  alert_notification_channels = [for c in google_monitoring_notification_channel.alert_email : c.id]

  # Both Jobs run hourly with max_retries = 0, so each failed run is one
  # failed execution.
  export_jobs = {
    website_export  = "${var.namespace}-website-export"
    langfuse_export = "${var.namespace}-langfuse-export"
  }
}

resource "google_monitoring_alert_policy" "export_job_failed" {
  for_each = local.export_jobs

  project      = var.project_id
  display_name = "${each.value} Job execution failed"
  combiner     = "OR"

  conditions {
    display_name = "${each.value} execution completed as failed"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${each.value}\" AND resource.labels.location=\"${var.region}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result=\"failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "900s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = local.alert_notification_channels

  alert_strategy {
    auto_close = "3600s"
  }
}

# A Job whose trigger stops runs no execution, so the failed-execution policy
# above stays quiet. This one fires after three hours with no succeeded
# execution, whatever the cause: a paused or failing Scheduler trigger, a
# renamed or deleted Job, or every run failing. It is its own policy, as the
# apis stack's search_catalogue_heartbeat is, because an auto_close timer
# shorter than the absence would close the incident while no execution
# succeeds. The condition is PromQL: it returns 1 when the window's
# succeeded executions sum to less than one, and when the series is absent,
# so it also fires for a Job that has never succeeded, which a
# condition_absent misses because it needs a data point written after the
# policy is created.
resource "google_monitoring_alert_policy" "export_job_not_succeeding" {
  for_each = local.export_jobs

  project      = var.project_id
  display_name = "${each.value} Job not succeeding"
  combiner     = "OR"

  conditions {
    display_name = "no succeeded ${each.value} execution in 3 hours"

    condition_prometheus_query_language {
      query               = "(sum(sum_over_time(run_googleapis_com:job_completed_execution_count{monitored_resource=\"cloud_run_job\",job_name=\"${each.value}\",location=\"${var.region}\",result=\"succeeded\"}[3h])) < 1) or absent_over_time(run_googleapis_com:job_completed_execution_count{monitored_resource=\"cloud_run_job\",job_name=\"${each.value}\",location=\"${var.region}\",result=\"succeeded\"}[3h])"
      duration            = "0s"
      evaluation_interval = "300s"
    }
  }

  notification_channels = local.alert_notification_channels

  alert_strategy {
    auto_close = "604800s"
  }
}
