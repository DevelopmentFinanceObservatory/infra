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
