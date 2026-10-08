# Analysis frames the AI runtime creates and reads. A derived frame's object
# holds the only copy of its op-spec, which recomputing the frame on newer
# data replays, so the bucket has no age rule.
resource "google_storage_bucket" "materialisation_store" {
  name     = "${var.project_id}-ai-materialisation-store"
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  versioning {
    enabled = false
  }
  force_destroy = false

  soft_delete_policy {
    retention_duration_seconds = 0
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket_iam_member" "materialisation_store_creator" {
  bucket = google_storage_bucket.materialisation_store.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${module.ai_service.runtime_service_account_email}"
}

resource "google_storage_bucket_iam_member" "materialisation_store_viewer" {
  bucket = google_storage_bucket.materialisation_store.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${module.ai_service.runtime_service_account_email}"
}
