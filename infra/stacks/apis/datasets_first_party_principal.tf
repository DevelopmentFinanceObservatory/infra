# The datasets first-party principal: the shared bearer value the publish
# door compares the `x-dfo-principal` header against
# (`datasets_api.doors.publish`). Unset, the door reads an empty allowlist
# and refuses every caller regardless of header -- its own fail-closed
# default. The pin door reads its own separate value, generated in
# datasets_pin_principal.tf.
# While var.allow_unauthenticated is true, any caller reaches the apis
# service, so a caller who learns this value reaches publish. With it false,
# only identities holding an invoker grant reach the service and this value is
# a second check behind Cloud Run IAM. See "Caller authentication" in the README.

locals {
  # Single counter for the write-only pair below. The ephemeral value
  # regenerates every plan but only reaches the secret version when this
  # number changes. Bump it to rotate.
  datasets_first_party_principal_version = 1
}

# Alphanumeric only, so the value drops into the `x-dfo-principal` header, a
# curl command, or an env file with no escaping anywhere.
ephemeral "random_password" "datasets_first_party_principal" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "datasets_first_party_principal" {
  secret_id = "${var.namespace}-datasets-first-party-principal"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "datasets_first_party_principal" {
  secret                 = google_secret_manager_secret.datasets_first_party_principal.id
  secret_data_wo         = ephemeral.random_password.datasets_first_party_principal.result
  secret_data_wo_version = local.datasets_first_party_principal_version

  lifecycle {
    # A counter bump replaces this resource, and the replacement must exist
    # before the old version is destroyed so this stack's own pinned
    # reference never points at nothing.
    create_before_destroy = true
  }
}

# Humans who need to read the value directly -- to publish from a laptop
# against deployed dev, or to configure a local `.env` that points at
# deployed dev instead of a local dfo-apis -- read it from Secret Manager
# rather than passing it around; each grant is scoped to this one secret.
# Empty by default: the `apis` and `ai` services carry the value between
# themselves through their own `secret_env_vars` grants (below, and in
# `../ai/main.tf`), so no human needs read access until one does.
resource "google_secret_manager_secret_iam_member" "datasets_first_party_principal_readers" {
  for_each  = toset(var.datasets_first_party_principal_readers)
  secret_id = google_secret_manager_secret.datasets_first_party_principal.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}
