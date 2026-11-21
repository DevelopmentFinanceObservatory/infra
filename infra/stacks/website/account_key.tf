# The ID hashing key, in every tier. The website service mounts it as
# EXPORT_ID_HMAC_KEY and HMACs a signed-in user's id with it into the
# x-dfo-account header it sends the Studio harness (dfo-website
# src/lib/proxy/account.ts). Where the event export runs (event_export.tf),
# the export Job hashes user ids with the same key and version, so a Studio
# account digest equals the exported user hash.
#
# The secret keeps its export-era name and addresses: dfo-prod's secret
# `dfo-prod-website-export-hmac-key` and its version 1 predate this file, and
# a new value would change every exported user hash and every account digest.

locals {
  # Single counter for the write-only pair below. The ephemeral key regenerates
  # every plan but only reaches the secret version when this number changes.
  # Bump it to rotate. Rotating changes every hashed id, so exported rows
  # loaded before and after no longer join, and every Studio account digest
  # changes (see README.md).
  website_export_hmac_key_version = 1
}

# Alphanumeric only, following the better-auth secret pattern.
ephemeral "random_password" "website_export_hmac_key" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "website_export_hmac_key" {
  secret_id = "${local.website_name}-export-hmac-key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "website_export_hmac_key" {
  secret                 = google_secret_manager_secret.website_export_hmac_key.id
  secret_data_wo         = ephemeral.random_password.website_export_hmac_key.result
  secret_data_wo_version = local.website_export_hmac_key_version

  lifecycle {
    # A counter bump replaces this resource, and the replacement must exist
    # before the old version is destroyed so the service's and the Job's
    # pinned references never point at nothing.
    create_before_destroy = true
  }
}

# dfo-prod's state holds the key at index 0 from when the export alone
# created it. dfo-dev's state has nothing there, so these are no-ops there.
moved {
  from = google_secret_manager_secret.website_export_hmac_key[0]
  to   = google_secret_manager_secret.website_export_hmac_key
}

moved {
  from = google_secret_manager_secret_version.website_export_hmac_key[0]
  to   = google_secret_manager_secret_version.website_export_hmac_key
}
