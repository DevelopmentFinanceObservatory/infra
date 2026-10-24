# The bucket Langfuse's blob storage export writes to, and the identity it
# writes as. Langfuse Cloud pushes Parquet files for core, basic, time, model,
# usage, metrics and trace_context fields under a prefix in this bucket every
# hour. The io, metadata, tools and prompt field groups stay off in Langfuse,
# so prompts, answers, metadata and tool arguments never reach GCS.
#
# Langfuse connects as S3-compatible storage at https://storage.googleapis.com
# with an HMAC key on the writer account. The key is created by hand
# (infra/dfo-prod/ai/README.md, "Langfuse blob storage export"), so no key
# material is in Terraform or its state.
#
# Gated by var.langfuse_export_enabled like the rest of langfuse_export.tf.

# GCS bucket names are global; the namespace and project id make this one
# unique, as the apis stack's coverage bucket does.
resource "google_storage_bucket" "langfuse_export_blob" {
  count = local.langfuse_export_count

  name     = "${var.namespace}-langfuse-export-${var.project_id}"
  project  = var.project_id
  location = "EU"

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  versioning {
    enabled = false
  }
  force_destroy = false

  # An export file still holds `status_message`, which BigQuery never receives.
  # Zero soft-delete retention makes the 90-day rule the whole retention.
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_service_account" "langfuse_export_blob_writer" {
  count = local.langfuse_export_count

  project      = var.project_id
  account_id   = "${var.namespace}-langfuse-blob"
  display_name = "Langfuse blob storage export writer"
}

# Langfuse overwrites a retried file at the same key (storage.objects.delete)
# and its S3 client uploads large files as multipart uploads. Nothing reads
# the bucket as this account.
resource "google_project_iam_custom_role" "langfuse_export_blob_writer" {
  count = local.langfuse_export_count

  project     = var.project_id
  role_id     = "${replace(var.namespace, "-", "_")}_langfuse_blob_writer"
  title       = "Langfuse blob storage export writer"
  description = "Write and replace objects, including multipart uploads, without read or list."
  permissions = [
    "storage.objects.create",
    "storage.objects.delete",
    "storage.multipartUploads.create",
    "storage.multipartUploads.abort",
  ]
}

resource "google_storage_bucket_iam_member" "langfuse_export_blob_writer" {
  count = local.langfuse_export_count

  bucket = google_storage_bucket.langfuse_export_blob[0].name
  role   = google_project_iam_custom_role.langfuse_export_blob_writer[0].id
  member = google_service_account.langfuse_export_blob_writer[0].member
}

output "langfuse_export_bucket_name" {
  description = "Name of the Langfuse blob storage export bucket, null where the export is off. The bucket field in Langfuse's Blob Storage integration."
  value       = one(google_storage_bucket.langfuse_export_blob[*].name)
}

output "langfuse_export_blob_writer_email" {
  description = "Email of the service account that owns the HMAC key Langfuse's Blob Storage integration uses, null where the export is off. The --service-account of `gcloud storage hmac create`."
  value       = one(google_service_account.langfuse_export_blob_writer[*].email)
}
