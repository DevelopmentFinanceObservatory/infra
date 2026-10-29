# The caller HMAC key names a client by a keyed digest of its address. The
# website's `/mcp` proxy HMACs the client IP with it to form the `ip:<digest>`
# it sends as `x-dfo-caller`, and dfo-apis (`dfo_platform.caller`) keys a
# caller it sees directly with the same key, so both services name one client
# by one digest. The digest is the `ip:` caller in the combined MCP server's
# request log lines, the frame `writer` data-mcp and analysis-mcp record, and
# the key of each per-caller allowance in dfo-apis. Unset on the website, it
# sends no `x-dfo-caller`.
# This stack owns the key, rather than the website, because it applies first.
# The website reads the secret by id, and a revision that mounts a secret that
# does not exist yet fails to start.

locals {
  # Single counter for the write-only pair below. The ephemeral value
  # regenerates every plan but only reaches the secret version when this
  # number changes. Bump it to rotate. Rotating changes every visitor's caller
  # identity (see README.md).
  caller_hmac_key_version = 1
}

# Alphanumeric only, so the value drops into an env file with no escaping.
ephemeral "random_password" "caller_hmac_key" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "caller_hmac_key" {
  secret_id = "${var.namespace}-caller-hmac-key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "caller_hmac_key" {
  secret                 = google_secret_manager_secret.caller_hmac_key.id
  secret_data_wo         = ephemeral.random_password.caller_hmac_key.result
  secret_data_wo_version = local.caller_hmac_key_version

  lifecycle {
    # A counter bump replaces this resource, and the replacement must exist
    # before the old version is destroyed so this stack's own pinned
    # reference never points at nothing.
    create_before_destroy = true
  }
}

# Humans who need to read the key directly (to reproduce a caller digest from
# a log line) read it from Secret Manager, and each grant is scoped to this
# one secret. Empty by default, because this stack mounts it directly (in
# main.tf) and the `website` stack's service carries it through its own
# `secret_env_vars` grant, so no human needs read access until one does.
resource "google_secret_manager_secret_iam_member" "caller_hmac_key_readers" {
  for_each  = toset(var.caller_hmac_key_readers)
  secret_id = google_secret_manager_secret.caller_hmac_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}
