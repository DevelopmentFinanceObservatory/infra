# The website's caller HMAC key, which the /mcp proxy signs the client IP with so the harness sees a stable, non-reversible x-dfo-caller identity for each visitor.

locals {
  # Single counter for the write-only pair below. The ephemeral key regenerates every plan but only reaches the secret version when this number changes. Bump it to rotate. Rotating changes every visitor's caller identity (see README.md).
  website_caller_hmac_key_version = 1
}

# Alphanumeric only, following the better-auth secret pattern.
ephemeral "random_password" "website_caller_hmac_key" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "website_caller_hmac_key" {
  secret_id = "${local.website_name}-caller-hmac-key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "website_caller_hmac_key" {
  secret                 = google_secret_manager_secret.website_caller_hmac_key.id
  secret_data_wo         = ephemeral.random_password.website_caller_hmac_key.result
  secret_data_wo_version = local.website_caller_hmac_key_version

  lifecycle {
    # A counter bump replaces this resource, and the replacement must exist before the old version is destroyed so the service's pinned reference never points at nothing.
    create_before_destroy = true
  }
}
