# The share import principal is the shared bearer value that gates
# `PUT /api/presentation/shares/{share_id}/import`, which compares the
# `x-dfo-principal` header against it. The website's share migration Job
# (the `website` stack's share_migrate_job.tf) sends it once per share while
# it moves the website's `share` rows into the Presentation store. Unset or
# empty, the route refuses every caller.
# It is a separate value from every other principal in this stack. The route
# creates shares under ids and creation times the caller chooses and spends no
# allowance, so the value has to be revocable without touching the website
# service's own principals.
# While var.allow_unauthenticated is true, any caller reaches the apis
# service, so a caller who learns this value reaches the import route. With it
# false, only identities holding an invoker grant reach the service and this
# value is a second check behind Cloud Run IAM.
# The route and this secret are removed once prod's shares are migrated.
# This stack applies before `website`, which `apply.yml` does by listing it
# as a producer stack. The website Job reads the secret by id, and its
# accessor grant fails while the secret does not exist.

locals {
  # Single counter for the write-only pair below. The ephemeral value
  # regenerates every plan but only reaches the secret version when this
  # number changes. Bump it to rotate.
  share_import_principal_version = 1
}

# Alphanumeric only, so the value drops into the `x-dfo-principal` header, a
# curl command, or an env file with no escaping anywhere.
ephemeral "random_password" "share_import_principal" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "share_import_principal" {
  secret_id = "${var.namespace}-share-import-principal"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "share_import_principal" {
  secret                 = google_secret_manager_secret.share_import_principal.id
  secret_data_wo         = ephemeral.random_password.share_import_principal.result
  secret_data_wo_version = local.share_import_principal_version

  lifecycle {
    # A counter bump replaces this resource, and the replacement must exist
    # before the old version is destroyed so this stack's own pinned
    # reference never points at nothing.
    create_before_destroy = true
  }
}
