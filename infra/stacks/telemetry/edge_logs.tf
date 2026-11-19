# The bucket Cloudflare Logpush writes the edge's dataset-read request lines
# to. The job itself lives in the edge-logs stack (cloudflare_logpush.tf),
# which reads this bucket's name from its own edge_logpush_bucket variable,
# copied from the edge_logs_bucket output below. The lines carry raw client IPs, so
# the bucket keeps them for one day.
#
# Cloudflare names each batch <start>_<end>_<hash>.log.gz and writes its
# ownership challenge as ownership-challenge-<random>.txt
# (https://developers.cloudflare.com/logs/logpush/logpush-job/logpush-ownership-challenge/).
# The delete rule matches the .log.gz suffix only, so the challenge file, a
# token bound to this zone and bucket with no request data in it, stays for
# the edge-logs stack's plan to read.
resource "google_storage_bucket" "edge_logs" {
  name     = "${var.namespace}-edge-logs-${var.project_id}"
  project  = var.project_id
  location = local.bigquery_location

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = false
  }

  # One day is the shortest age GCS supports. GCS deletes an object some time
  # after it reaches the age, usually within a day, so a line lives one to two
  # days (https://cloud.google.com/storage/docs/lifecycle#behavior).
  lifecycle_rule {
    condition {
      age            = 1
      matches_suffix = [".log.gz"]
    }
    action {
      type = "Delete"
    }
  }

  # A soft-deleted object can be restored, raw IPs included, so nothing is
  # kept past the lifecycle delete.
  soft_delete_policy {
    retention_duration_seconds = 0
  }
}

# The role Cloudflare's GCS destination page asks for
# (https://developers.cloudflare.com/logs/logpush/logpush-job/enable-destinations/google-cloud-storage/).
# Logpush writes batches and the ownership challenge file with it.
resource "google_storage_bucket_iam_member" "edge_logs_cloudflare_logpush" {
  bucket = google_storage_bucket.edge_logs.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:logpush@cloudflare-data.iam.gserviceaccount.com"
}

output "edge_logs_bucket" {
  description = "Bucket Cloudflare Logpush writes the edge's dataset-read request lines to. Copy it into the edge-logs stack's edge_logpush_bucket."
  value       = google_storage_bucket.edge_logs.name
}
