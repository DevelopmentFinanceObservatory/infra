# Counts website requests to the data API paths (/api/search, /api/datasets
# and /api/graph, with or without the /api/v1 prefix), by DFO client library
# and HTTP status. Cloud Run's request log records the user agent, URL and status
# of every request, so the website needs no logging of its own. The DFO
# client libraries send `User-Agent: dfo-<language>/<version>`. The label
# takes only dfo-python, dfo-r and dfo-ts, so callers cannot add label values;
# raw REST callers, browsers and any other user agent get an empty `client`.
#
# Nothing in this stack reads the metric, so the propagation wait that
# apis/coverage.tf puts between a metric and its alert policy has no use here.
# Add one before any alert policy or dashboard that filters on this metric in
# the same apply.
resource "google_logging_metric" "client_calls" {
  name        = "${local.website_name}-client-calls"
  project     = var.project_id
  description = "Requests to the data API paths (/api/search, /api/datasets and /api/graph, with or without the /api/v1 prefix) on the ${local.website_name} service, by DFO client library and HTTP status."
  filter      = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${module.website_service.service_name}"
    resource.labels.location="${var.region}"
    logName="projects/${var.project_id}/logs/run.googleapis.com%2Frequests"
    httpRequest.requestUrl=~"^https?://[^/]+/api/(v1/)?(search|datasets|graph)(/|[?]|$)"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "client"
      value_type  = "STRING"
      description = "The DFO client library named at the start of the User-Agent header: dfo-python, dfo-r or dfo-ts. Empty for any other caller."
    }

    labels {
      key         = "status"
      value_type  = "STRING"
      description = "The HTTP status code, such as 200 or 404. Group by class at query time."
    }
  }

  label_extractors = {
    client = "REGEXP_EXTRACT(httpRequest.userAgent, \"^(dfo-python|dfo-r|dfo-ts)/\")"
    status = "EXTRACT(httpRequest.status)"
  }
}
