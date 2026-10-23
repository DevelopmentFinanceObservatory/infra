terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      # Every other prod root is locked to 7.x. The cap keeps this one on the
      # same line until they move together.
      source  = "hashicorp/google"
      version = ">= 5.11.0, < 8.0.0"
    }
    time = {
      # time_sleep in logs_daily.tf, which waits out a new log-based metric's
      # propagation to Cloud Monitoring before the alert policy names it.
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
    "bigquerydatatransfer.googleapis.com",
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

# The reporting readers (reporting.tf) and alert recipients (alerts.tf) come
# from this hand-made secret, so no address sits in the repository or in plan
# output. It holds
#   {"readers": {"<label>": "group:<address>"}, "alerts": {"<label>": "<address>"}}
# and scripts/bootstrap-principals.sh writes it. Resources are keyed by label,
# since Terraform rejects sensitive for_each keys and an address in a key
# would print in every plan, so a label may hold only lower-case letters,
# digits, hyphens and underscores.
data "google_secret_manager_secret_version" "principals" {
  secret = "projects/${var.project_id}/secrets/${var.namespace}-telemetry-principals"

  lifecycle {
    postcondition {
      condition = try(alltrue(concat(
        [for label in keys(jsondecode(self.secret_data).readers) : can(regex("^[a-z0-9_-]+$", label))],
        [for label in keys(jsondecode(self.secret_data).alerts) : can(regex("^[a-z0-9_-]+$", label))],
      )), false)
      error_message = "The principals secret must be a JSON object with readers and alerts objects, each keyed by labels of lower-case letters, digits, hyphens and underscores."
    }
    postcondition {
      condition     = try(alltrue([for m in values(jsondecode(self.secret_data).readers) : can(regex("^(group|user|serviceAccount|domain):[^:]+$", m))]), false)
      error_message = "Each readers value in the principals secret must be group:, user:, serviceAccount: or domain: followed by an address."
    }
    postcondition {
      condition     = try(length(jsondecode(self.secret_data).alerts) > 0 && alltrue([for e in values(jsondecode(self.secret_data).alerts) : can(regex("^[^@:\\s]+@[^@:\\s]+$", e))]), false)
      error_message = "The principals secret's alerts object must hold at least one bare email address, with no member prefix."
    }
    postcondition {
      condition = try(alltrue([
        for obj in [jsondecode(self.secret_data).readers, jsondecode(self.secret_data).alerts] :
        length(distinct(values(obj))) == length(obj)
      ]), false)
      error_message = "An object in the principals secret holds the same value under two labels, so removing either label would revoke or unsubscribe both."
    }
  }
}

locals {
  principals = jsondecode(data.google_secret_manager_secret_version.principals.secret_data)
}
