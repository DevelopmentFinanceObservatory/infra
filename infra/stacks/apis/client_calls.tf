# Counts HTTP requests from the DFO client libraries, by client and status. Each
# library names itself in X-DFO-Client, which the website forwards, and
# dfo_platform.caller logs the parsed name as client_name on the
# dfo_platform.request line. The libraries reserve that header, so a custom
# User-Agent leaves the count unchanged. The caller writes the value, so the
# extractor's fixed list bounds the label and any other name lands in one empty
# bucket.
#
# One library call can be many requests: polls, re-posts, retries and file
# downloads all count. A browser's dataset download carries no X-DFO-Client and
# is missed. Requests refused before the app logs them are missed too, so use
# the run.googleapis.com/requests log for failure rates.
resource "google_logging_metric" "client_calls" {
  name        = "${var.namespace}-client-calls"
  project     = var.project_id
  description = "HTTP requests to the ${module.apis_service.service_name} service that name a client in X-DFO-Client, by client and status."
  filter      = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${module.apis_service.service_name}"
    resource.labels.location="${var.region}"
    jsonPayload.logger="dfo_platform.request"
    jsonPayload.client_name:*
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "client"
      value_type  = "STRING"
      description = "The DFO client library from the X-DFO-Client header: dfo-python or dfo-ts. Empty for any other name."
    }

    labels {
      key         = "status"
      value_type  = "STRING"
      description = "The HTTP status code the service logged, such as 200 or 404. Empty when the request ended with no response. Group by class at query time."
    }
  }

  label_extractors = {
    client = "REGEXP_EXTRACT(jsonPayload.client_name, \"^(dfo-python|dfo-ts)$\")"
    status = "EXTRACT(jsonPayload.http_status)"
  }
}
