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
# user_by_email, as the BigQuery API expects. Each grant is keyed by the
# member's label in the principals secret (main.tf), and the member and its
# parts stay sensitive.
locals {
  reporting_reader_principals = {
    for label in nonsensitive(keys(local.principals.readers)) : label => {
      member  = local.principals.readers[label]
      kind    = split(":", local.principals.readers[label])[0]
      address = split(":", local.principals.readers[label])[1]
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
  for_each = local.reporting_reader_principals

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = each.value.member
}

# The dashboard reads through Google's managed BigQuery MCP server at
# https://bigquery.googleapis.com/mcp. A tool call there needs this role on
# the project, and the query it runs needs the BigQuery grants above.
resource "google_project_iam_member" "reporting_readers_mcp_tool_user" {
  for_each = local.reporting_reader_principals

  project = var.project_id
  role    = "roles/mcp.toolUser"
  member  = each.value.member
}
