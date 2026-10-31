# The caller principal is the shared value that lets dfo-apis trust the
# `x-dfo-caller` header. The website and dfo-ai send it as
# `x-dfo-caller-principal` beside that header, and dfo-apis
# (`dfo_platform.caller.resolve_caller`) names the caller by `x-dfo-caller`
# only when the principal matches. The pin door and the per-caller allowances
# then count each website visitor or `/mcp` client separately. A request whose
# `x-dfo-caller-principal` matches no configured value, including when dfo-apis
# has none, is refused 503 (`CallerUnresolved`), so a rotation answers 503 to a
# website or dfo-ai instance still holding the old value until it restarts.
# Unset on the website or dfo-ai, neither header is sent.
# It is a separate value from `live_refresh_principal.tf`'s and the two
# datasets principals. It grants no route by itself, only trust in a caller
# name, so its allowlist rotates independently of theirs.
# While var.allow_unauthenticated is true, any caller reaches the apis
# service, so a caller who learns this value can name itself as any visitor
# and spend that visitor's allowance. With it false, only identities holding
# an invoker grant reach the service and this value is a second check behind
# Cloud Run IAM.
# This stack applies before `ai` and `website`, which `apply.yml` does by
# listing it as a producer stack. Both read the secret by id, and a revision
# that mounts a secret that does not exist yet fails to start.

locals {
  # Single counter for the write-only pair below. The ephemeral value
  # regenerates every plan but only reaches the secret version when this
  # number changes. Bump it to rotate.
  caller_principal_version = 1
}

# Alphanumeric only, so the value drops into the `x-dfo-caller-principal`
# header, a curl command, or an env file with no escaping anywhere.
ephemeral "random_password" "caller_principal" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "caller_principal" {
  secret_id = "${var.namespace}-caller-principal"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "caller_principal" {
  secret                 = google_secret_manager_secret.caller_principal.id
  secret_data_wo         = ephemeral.random_password.caller_principal.result
  secret_data_wo_version = local.caller_principal_version

  lifecycle {
    # A counter bump replaces this resource, and the replacement must exist
    # before the old version is destroyed so this stack's own pinned
    # reference never points at nothing.
    create_before_destroy = true
  }
}

# Humans who need to read the value directly (to call dfo-apis as a named
# caller from a laptop, or to configure a local `.env` that points at
# deployed dev) read it from Secret Manager, and each grant is scoped to this
# one secret. Empty by default, because this stack mounts it directly (in
# main.tf) and the `ai` and `website` stacks' services carry it through their
# own `secret_env_vars` grants, so no human needs read access until one does.
resource "google_secret_manager_secret_iam_member" "caller_principal_readers" {
  for_each  = toset(var.caller_principal_readers)
  secret_id = google_secret_manager_secret.caller_principal.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}
