terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      # Every other prod root is locked to 7.x. The cap keeps this one on the
      # same line until they move together.
      source  = "hashicorp/google"
      version = ">= 5.11.0, < 8.0.0"
    }
    time = {
      # time_sleep in analytics_jobs.tf, which waits out a new log-based
      # metric's propagation to Cloud Monitoring before an alert policy names
      # it.
      source  = "hashicorp/time"
      version = ">= 0.9.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "this" {}

resource "google_project_service" "apis" {
  for_each = toset([
    "logging.googleapis.com",
    "bigquery.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

# Every telemetry source lands in the EU multi-region, so views in
# dfo_reporting can read all of them in one query. Cloud Logging and BigQuery
# spell the same location differently.
locals {
  log_location      = "eu"
  bigquery_location = "EU"
}

# The reporting readers (reporting.tf), analytics developers (analytics.tf) and
# alert recipients (alerts.tf), read from a hand-made secret. The module holds
# the rules and this stack's schema, and scripts/bootstrap-principals.sh
# writes it.
module "principals" {
  source = "../../modules/principals-secret"

  project_id = var.project_id
  namespace  = var.namespace
  stack      = "telemetry"
}

locals {
  principals = module.principals.principals
}

# Readers and analytics developers both run BigQuery jobs, and a project
# binding is one per member and role, so roles/bigquery.jobUser is granted
# once per label over the union of the two objects. A person in both carries
# the same label in each, so removing them from one object leaves the label,
# and the grant, in place while the other still lists them. The precondition
# refuses a label that names two members and a member under two labels, either
# of which would put one binding under two instances, where destroying one
# revokes the other.
locals {
  people_job_user_principals = {
    for label in setunion(nonsensitive(keys(local.principals.readers)), nonsensitive(keys(local.principals.analytics_developers))) :
    label => try(local.principals.readers[label], local.principals.analytics_developers[label])
  }

  people_job_user_labels_consistent = nonsensitive(alltrue([
    for label, member in local.principals.analytics_developers :
    contains(keys(local.principals.readers), label) ? local.principals.readers[label] == member : !contains(values(local.principals.readers), member)
  ]))
}

resource "google_project_iam_member" "people_job_user" {
  for_each = local.people_job_user_principals

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = each.value

  lifecycle {
    precondition {
      condition     = local.people_job_user_labels_consistent
      error_message = "A member listed in both readers and analytics_developers must carry the same label in each, and a label in both must name the same member."
    }
  }
}

# The readers' grants were reporting_readers_job_user in reporting.tf, keyed
# by the same labels, so their live bindings move with no change.
moved {
  from = google_project_iam_member.reporting_readers_job_user
  to   = google_project_iam_member.people_job_user
}
