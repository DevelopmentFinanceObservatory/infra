# Counts requests from the DFO client libraries, by client and HTTP status. Each
# library names itself in X-DFO-Client, which the website forwards, and
# dfo_platform.caller logs the parsed name as client_name on every
# dfo_platform.request line. The libraries reserve that header, so a custom
# User-Agent leaves the count unchanged. The caller writes the value, so the
# filter's fixed list keeps callers from adding label values. Operation polls
# are left out, since one long build polls dozens of times. Retries count.
resource "google_logging_metric" "client_calls" {
  name        = "${var.namespace}-client-calls"
  project     = var.project_id
  description = "Requests to the ${module.apis_service.service_name} service from the DFO client libraries, by client and HTTP status, leaving out operation polls."
  filter      = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${module.apis_service.service_name}"
    resource.labels.location="${var.region}"
    jsonPayload.logger="dfo_platform.request"
    jsonPayload.client_name=~"^(dfo-python|dfo-ts)$"
    NOT jsonPayload.http_path=~"/operations/"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "client"
      value_type  = "STRING"
      description = "The DFO client library from the X-DFO-Client header: dfo-python or dfo-ts."
    }

    labels {
      key         = "status"
      value_type  = "STRING"
      description = "The HTTP status code, such as 200 or 404. Group by class at query time."
    }
  }

  label_extractors = {
    client = "EXTRACT(jsonPayload.client_name)"
    status = "EXTRACT(jsonPayload.http_status)"
  }
}
