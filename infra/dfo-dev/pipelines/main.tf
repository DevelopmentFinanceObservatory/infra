terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      # 5.22.0 introduced soft_delete_policy on google_storage_bucket, which
      # the buckets below set.
      source  = "hashicorp/google"
      version = ">= 5.22.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_storage_bucket" "raw" {
  name                        = "${var.project_id}-pipelines-raw"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  soft_delete_policy {
    retention_duration_seconds = 7776000 # 90 days
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket" "processed" {
  name                        = "${var.project_id}-pipelines-processed"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  soft_delete_policy {
    retention_duration_seconds = 7776000 # 90 days
  }

  lifecycle {
    prevent_destroy = true
  }
}

# One BigQuery dataset per pipeline in the format `<source>_<dataset>`
# Terraform owns the datasets but the pipelines own the tables inside them.
locals {
  bigquery_datasets = toset([
    "dfo_ontology",
    "data_commons_mappings",
    "oecd_dac_codelists",
    "oecd_dac_crs",
  ])
}

resource "google_bigquery_dataset" "pipelines" {
  for_each = local.bigquery_datasets

  dataset_id = each.key
  location   = var.region

  # `terraform destroy` on a dataset that still holds tables fails.
  delete_contents_on_destroy = false

  # Datasets can't be destroyed by Terraform.
  lifecycle {
    prevent_destroy = true
  }
}
