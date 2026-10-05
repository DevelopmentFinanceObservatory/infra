# The datasets pin principal: the shared bearer value the pin door compares
# the `x-dfo-principal` header against (`datasets_api.doors.pin`). Unset, the
# door reads an empty allowlist and refuses every caller regardless of
# header -- its own fail-closed default. A separate value from
# `datasets_first_party_principal.tf`'s: a pin has no unpin route, so
# holding this value lets a caller commit a dataset artifact permanently, a
# narrower but more consequential grant than the publish door's value, and
# the two doors' allowlists have to be free to rotate independently.
# This is interim. It does not close the exposure "Unauthenticated writes on
# the Datasets surface" the README records: the apis service still has `allUsers` as
# an invoker with no proxy validating the caller, so an internet caller who
# learns this value reaches pin the same as one who does not know it reaches
# the other writes. A generated secret is what keeps the value from being
# guessable on the first try, not what removes the exposure. It retires into
# ONEcampaign/dfo-ai#41, the tracking issue for the service-to-service ID
# tokens data-mcp does not mint today; once that lands, the door
# authenticates the caller instead of comparing a shared value.

locals {
  # Single counter for the write-only pair below. The ephemeral value
  # regenerates every plan but only reaches the secret version when this
  # number changes. Bump it to rotate.
  datasets_pin_principal_version = 1
}

# Alphanumeric only, so the value drops into the `x-dfo-principal` header, a
# curl command, or an env file with no escaping anywhere.
ephemeral "random_password" "datasets_pin_principal" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "datasets_pin_principal" {
  secret_id = "${var.namespace}-datasets-pin-principal"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "datasets_pin_principal" {
  secret                 = google_secret_manager_secret.datasets_pin_principal.id
  secret_data_wo         = ephemeral.random_password.datasets_pin_principal.result
  secret_data_wo_version = local.datasets_pin_principal_version

  lifecycle {
    # A counter bump replaces this resource, and the replacement must exist
    # before the old version is destroyed so this stack's own pinned
    # reference never points at nothing.
    create_before_destroy = true
  }
}

# Humans who need to read the value directly -- to pin from a laptop against
# deployed dev, or to configure a local `.env` that points at deployed dev
# instead of a local dfo-apis -- read it from Secret Manager rather than
# passing it around; each grant is scoped to this one secret. Empty by
# default: this stack mounts it directly (below), and the `website` stack's
# service carries it between the two through its own
# `secret_env_vars` grant (see that stack's `main.tf`), so no human needs
# read access until one does.
resource "google_secret_manager_secret_iam_member" "datasets_pin_principal_readers" {
  for_each  = toset(var.datasets_pin_principal_readers)
  secret_id = google_secret_manager_secret.datasets_pin_principal.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}
