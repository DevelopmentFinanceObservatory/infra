# The studio API token: the shared bearer secret harness.auth compares studio requests against in constant time.
# Until this is set on the service, the harness accepts any non-empty bearer token and logs STUDIO AUTH IS OPEN at startup, on a public URL.
# This is the interim scheme #12 anticipated: the settled end-state is service-to-service ID tokens with the harness off public access, and this secret retires when that lands.

locals {
  # Single counter for the write-only pair below. The ephemeral token regenerates every plan but only reaches the secret version when this number changes. Bump it to rotate.
  # The #132 divergence needs two write-only consumers of one value landing independently; this value has one consumer, so that failure mode does not arise here.
  studio_api_token_version = 1
}

# Alphanumeric only, so the value drops into an Authorization header, a curl command, or an env file with no escaping anywhere.
ephemeral "random_password" "studio_api_token" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "studio_api_token" {
  secret_id = "${var.namespace}-studio-api-token"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "studio_api_token" {
  secret                 = google_secret_manager_secret.studio_api_token.id
  secret_data_wo         = ephemeral.random_password.studio_api_token.result
  secret_data_wo_version = local.studio_api_token_version

  lifecycle {
    # A counter bump replaces this resource, and the replacement must exist before the old version is destroyed so the service's pinned reference never points at nothing.
    create_before_destroy = true
  }
}

# Humans who send studio requests from their own machines read the value from Secret Manager rather than passing it around; each grant is scoped to this one secret.
# The members come from the principals secret's studio_token_readers object (main.tf), keyed by label.
# The service's own read arrives through the module's secret_env_vars grant, not here.
resource "google_secret_manager_secret_iam_member" "studio_api_token_reader" {
  for_each  = toset(nonsensitive(keys(local.principals.studio_token_readers)))
  secret_id = google_secret_manager_secret.studio_api_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.principals.studio_token_readers[each.key]
}

# The resource above was once keyed by member string. Its old state entries are forgotten, so the live bindings stay, and the label-keyed resource re-creates the same bindings, which IAM accepts as no change.
removed {
  from = google_secret_manager_secret_iam_member.studio_api_token_readers
  lifecycle {
    destroy = false
  }
}
