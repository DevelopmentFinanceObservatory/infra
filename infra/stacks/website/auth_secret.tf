# The website's Better Auth secret: the key better-auth signs and
# verifies session cookies/JWTs with.

locals {
  # Single counter for the write-only pair below. The ephemeral secret regenerates every plan but only reaches the secret version when this number changes. Bump it to rotate. Rotating signs every user out (see README.md).
  website_better_auth_secret_version = 1
}

# Alphanumeric only, following the ai stack's studio token pattern.
ephemeral "random_password" "website_better_auth_secret" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "website_better_auth_secret" {
  secret_id = "${local.website_name}-better-auth-secret"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "website_better_auth_secret" {
  secret                 = google_secret_manager_secret.website_better_auth_secret.id
  secret_data_wo         = ephemeral.random_password.website_better_auth_secret.result
  secret_data_wo_version = local.website_better_auth_secret_version

  lifecycle {
    # A counter bump replaces this resource, and the replacement must exist before the old version is destroyed so the service's pinned reference never points at nothing.
    create_before_destroy = true
  }
}
