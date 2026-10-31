# The search query HMAC key keys the `query_hmac` field of the search `resolve`
# log line. dfo-apis HMACs each query with it, so repeats of a query count
# within a deployment, and guessing a query from the logs needs the key.
# Rotating it changes every digest, so repeat counts break across the rotation.
# Only the apis service reads it.

locals {
  # Single counter for the write-only pair below. The ephemeral value
  # regenerates every plan but only reaches the secret version when this
  # number changes. Bump it to rotate.
  search_query_hmac_key_version = 1
}

# Alphanumeric only, so the value drops into an env file with no escaping.
ephemeral "random_password" "search_query_hmac_key" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "search_query_hmac_key" {
  secret_id = "${var.namespace}-search-query-hmac-key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "search_query_hmac_key" {
  secret                 = google_secret_manager_secret.search_query_hmac_key.id
  secret_data_wo         = ephemeral.random_password.search_query_hmac_key.result
  secret_data_wo_version = local.search_query_hmac_key_version

  lifecycle {
    # A counter bump replaces this resource, and the replacement must exist
    # before the old version is destroyed so this stack's own pinned
    # reference never points at nothing.
    create_before_destroy = true
  }
}
