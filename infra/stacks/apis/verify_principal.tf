# The verify principal is the shared bearer value that holds dfo-apis' `verify`
# grant. It opens `POST /api/datasets/analysis` with `verify` set, which
# recomputes a stored analysis frame and stores nothing, and
# `GET /api/presentation/share-sample`, which lists a random sample of shares.
# Both compare the `x-dfo-principal` header against it, and refuse every
# caller with `verify_not_permitted` while it is unset or empty. The telemetry
# stack's replay Job (`dfo_analytics.replay`) is its only caller.
# It is a separate value from every other principal in this stack. It opens no
# other route, and the share sample names share ids, which no other caller
# should read.
# While var.allow_unauthenticated is true, any caller reaches the apis
# service, so a caller who learns this value reaches both routes. With it
# false, only identities holding an invoker grant reach the service and this
# value is a second check behind Cloud Run IAM.
# This stack applies before `telemetry`, which `apply.yml` does by listing it
# as a producer stack. The replay Job reads the secret by id, and its
# accessor grant fails while the secret does not exist.

locals {
  # Single counter for the write-only pair below. The ephemeral value
  # regenerates every plan but only reaches the secret version when this
  # number changes. Bump it to rotate.
  verify_principal_version = 1
}

# Alphanumeric only, so the value drops into the `x-dfo-principal` header, a
# curl command, or an env file with no escaping anywhere.
ephemeral "random_password" "verify_principal" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "verify_principal" {
  secret_id = "${var.namespace}-verify-principal"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "verify_principal" {
  secret                 = google_secret_manager_secret.verify_principal.id
  secret_data_wo         = ephemeral.random_password.verify_principal.result
  secret_data_wo_version = local.verify_principal_version

  lifecycle {
    # A counter bump replaces this resource, and the replacement must exist
    # before the old version is destroyed so this stack's own pinned
    # reference never points at nothing.
    create_before_destroy = true
  }
}
