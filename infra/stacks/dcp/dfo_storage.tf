# The stack declares the Data Commons artifacts bucket itself so it can
# carry lifecycle rules. The upstream storage module takes no lifecycle
# input, and the google provider's lifecycle_rule argument is a plain
# optional list, so rules added out of band on a module-owned bucket are
# stripped on the module's next apply. The moved block below re-parents
# the module's existing bucket onto this resource in place.
resource "google_storage_bucket" "dc_artifacts" {
  name                        = var.storage_artifacts_bucket_name
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = !var.stateful_deletion_protection

  # The name comes from storage_artifacts_bucket_name, the variable the
  # upstream module reads for the bucket it no longer creates, so the two
  # cannot disagree. Its upstream default is empty.
  lifecycle {
    precondition {
      condition     = var.storage_artifacts_bucket_name != ""
      error_message = "storage_artifacts_bucket_name is empty. Set it in this environment's dfo.auto.tfvars."
    }
  }

  # Dataflow's temp and staging location for the ingestion pipeline:
  # bundled jars, pipeline protos, and a per-run handshake JSON read once
  # within the run that wrote it.
  lifecycle_rule {
    condition {
      age            = 7
      matches_prefix = ["ingestion/internal/temp/"]
    }
    action {
      type = "Delete"
    }
  }

  # Per-run jsonld/<run> and process/<run> ingestion outputs, loaded into
  # Spanner by the run that produced them. The ingestion helper tracks run
  # state in its own database, so a month of history covers post-hoc
  # debugging.
  lifecycle_rule {
    condition {
      age            = 30
      matches_prefix = ["ingestion/internal/datacommons/"]
    }
    action {
      type = "Delete"
    }
  }

  # A Dataflow worker that dies mid-upload leaves an incomplete multipart
  # upload behind. A week is longer than any run.
  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }
}

moved {
  from = module.stack.module.storage.google_storage_bucket.artifacts_bucket[0]
  to   = google_storage_bucket.dc_artifacts
}
