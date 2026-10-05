# The definition store: an immutable, content-addressed cache of spec
# definitions data-mcp writes on `search` and reads back on `get_data`,
# keyed by a hash of their own contents. Objects are never updated once
# written and expire on a fixed age, so this is a single bucket plus a
# lifecycle rule rather than a database.

# GCS bucket names are globally unique across all of GCP, not just this
# project; the project-id prefix here is what gives us that uniqueness,
# matching the `dcp` stack's Datasets buckets (infra/stacks/dcp/dfo_datasets.tf).
resource "google_storage_bucket" "definition_store" {
  name     = "${var.project_id}-ai-definition-store"
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  versioning {
    enabled = false
  }
  force_destroy = false

  # Objects are content-addressed and immutable; nothing here is ever
  # overwritten, only created once and eventually aged out.
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

  # GCS soft delete defaults to a 7-day retention on every deleted object,
  # which would mean paying for a second copy of every object this bucket's
  # own lifecycle rule deletes, for a week past its deletion. There is
  # nothing worth recovering from an expired, content-addressed cache entry.
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  # No CORS block: definitions are read server-side by data-mcp, never
  # fetched directly by a browser the way the Datasets buckets' signed URLs
  # are.

  lifecycle {
    prevent_destroy = true
  }
}

# The ai runtime writes new definitions on `search` and reads them back on
# `get_data`. It never deletes — expiry is the bucket lifecycle rule above,
# not a code path — so this grants storage.objectCreator and
# storage.objectViewer only, the same split `apis/datasets_access.tf` uses
# for the Datasets API's runtime identity against its own buckets.
resource "google_storage_bucket_iam_member" "definition_store_creator" {
  bucket = google_storage_bucket.definition_store.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${module.ai_service.runtime_service_account_email}"
}

resource "google_storage_bucket_iam_member" "definition_store_viewer" {
  bucket = google_storage_bucket.definition_store.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${module.ai_service.runtime_service_account_email}"
}
