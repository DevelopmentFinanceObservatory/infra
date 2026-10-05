# Analysis frames are temporary objects the AI runtime creates and reads.
resource "google_storage_bucket" "materialisation_store" {
  name     = "${var.project_id}-ai-materialisation-store"
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  versioning {
    enabled = false
  }
  force_destroy = false

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

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
