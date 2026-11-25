# The one dataset the team dashboard reads. It holds aggregates only, with no
# user ids, IPs or free text, and its readers get no access to the datasets
# they are built from. The analytics repository's scheduled dbt build writes
# its tables, and its tests hold every column to that rule.
resource "google_bigquery_dataset" "reporting" {
  dataset_id  = "dfo_reporting"
  location    = local.bigquery_location
  description = "Reporting tables built from the DFO telemetry datasets by the analytics repository's scheduled dbt build, read by the team dashboard."

  depends_on = [google_project_service.apis]
}

# The scheduled dbt build is the one writer of dfo_reporting. The CI account
# and the analytics developers build into their own datasets and get no
# access here.
resource "google_bigquery_dataset_access" "analytics_runner_reporting" {
  dataset_id    = google_bigquery_dataset.reporting.dataset_id
  role          = "WRITER"
  user_by_email = google_service_account.analytics["runner"].email
}

# A dataset access entry names its principal by kind, so each member string
# splits into the field its prefix selects, group: or user:, the two forms the
# readers object accepts. Each grant is keyed by the member's label in the
# principals secret (main.tf), and the member and its parts stay sensitive.
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
  user_by_email  = each.value.kind == "user" ? each.value.address : null
}

# The dashboard reads through Google's managed BigQuery MCP server at
# https://bigquery.googleapis.com/mcp. A tool call there needs this role on
# the project, and the query it runs needs READER above and
# roles/bigquery.jobUser (people_job_user in main.tf).
resource "google_project_iam_member" "reporting_readers_mcp_tool_user" {
  for_each = local.reporting_reader_principals

  project = var.project_id
  role    = "roles/mcp.toolUser"
  member  = each.value.member
}
