# The MCP API token: the shared bearer secret the harness's MCP mounts (/mcp/data, /mcp/analysis, /mcp/presentation) compare requests against.
# Unset, the process mints a random token at startup for its own in-process clients only; setting it here is what lets callers outside the process reach the mounts.
# Health routes are unaffected either way.

locals {
  # Single counter for the write-only pair below. The ephemeral token regenerates every plan but only reaches the secret version when this number changes. Bump it to rotate.
  mcp_api_token_version = 1
}

# Alphanumeric only, so the value drops into an Authorization header, a curl command, or an env file with no escaping anywhere.
ephemeral "random_password" "mcp_api_token" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "mcp_api_token" {
  secret_id = "${var.namespace}-mcp-api-token"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "mcp_api_token" {
  secret                 = google_secret_manager_secret.mcp_api_token.id
  secret_data_wo         = ephemeral.random_password.mcp_api_token.result
  secret_data_wo_version = local.mcp_api_token_version

  lifecycle {
    # A counter bump replaces this resource, and the replacement must exist before the old version is destroyed so the service's pinned reference never points at nothing.
    create_before_destroy = true
  }
}

# Humans who call the MCP mounts directly, and whoever configures the out-of-repo e2e test daemon that points at this service's deployed URL, read the value from Secret Manager rather than passing it around; each grant is scoped to this one secret.
# The members come from the principals secret's mcp_token_readers object (main.tf), keyed by label.
# The service's own read arrives through the module's secret_env_vars grant, not here.
resource "google_secret_manager_secret_iam_member" "mcp_api_token_readers" {
  for_each  = toset(nonsensitive(keys(local.principals.mcp_token_readers)))
  secret_id = google_secret_manager_secret.mcp_api_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.principals.mcp_token_readers[each.key]
}
