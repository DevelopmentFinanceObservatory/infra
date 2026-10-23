# The one dataset the team dashboard reads. It holds views and aggregates
# only, with no user ids, IPs or free text, and its readers get no access to
# the datasets those views read.
resource "google_bigquery_dataset" "reporting" {
  dataset_id  = "dfo_reporting"
  location    = local.bigquery_location
  description = "Reporting views over the DFO telemetry datasets, read by the team dashboard."

  depends_on = [google_project_service.apis]
}

# A dataset access entry names its principal by kind, so each member string
# splits into the field its prefix selects. serviceAccount: members go in
# user_by_email, as the BigQuery API expects.
locals {
  reporting_reader_principals = {
    for m in var.reporting_readers : m => {
      kind    = split(":", m)[0]
      address = split(":", m)[1]
    }
  }
}

resource "google_bigquery_dataset_access" "reporting_readers" {
  for_each = local.reporting_reader_principals

  dataset_id     = google_bigquery_dataset.reporting.dataset_id
  role           = "READER"
  group_by_email = each.value.kind == "group" ? each.value.address : null
  user_by_email  = contains(["user", "serviceAccount"], each.value.kind) ? each.value.address : null
  domain         = each.value.kind == "domain" ? each.value.address : null
}

resource "google_project_iam_member" "reporting_readers_job_user" {
  for_each = toset(var.reporting_readers)

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = each.value
}

# The dashboard reads through Google's managed BigQuery MCP server at
# https://bigquery.googleapis.com/mcp. A tool call there needs this role on
# the project, and the query it runs needs the BigQuery grants above. The
# endpoint itself is enabled by hand (README "Made by hand first"), since the
# provider has no resource for it.
resource "google_project_iam_member" "reporting_readers_mcp_tool_user" {
  for_each = toset(var.reporting_readers)

  project = var.project_id
  role    = "roles/mcp.toolUser"
  member  = each.value
}
