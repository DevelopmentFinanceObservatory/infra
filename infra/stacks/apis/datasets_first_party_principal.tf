# The datasets first-party principal: the shared bearer value the publish
# door compares the `x-dfo-principal` header against
# (`datasets_api.doors.publish`). Unset, the door reads an empty allowlist
# and refuses every caller regardless of header -- its own fail-closed
# default. The pin door reads its own separate value, generated in
# datasets_pin_principal.tf.
# This is interim. It does not close the exposure "Unauthenticated writes on
# the Datasets surface" below records: the apis service still has `allUsers` as
# an invoker with no proxy validating the caller, so an internet caller who
# learns this value reaches publish the same as one who does not know it
# reaches the other writes. A generated secret is what keeps the value from
# being guessable on the first try, not what removes the exposure. It retires
# into ONEcampaign/dfo-ai#41, the tracking issue for the service-to-service ID
# tokens data-mcp does not mint today; once that lands, the door
# authenticates the caller instead of comparing a shared value.

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
