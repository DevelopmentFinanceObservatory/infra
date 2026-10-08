# The live-refresh principal is the shared bearer value that gates the routes a
# live Studio share calls each time it opens. On the dfo-apis side that is the
# dataset frame refresh route (`POST /api/datasets/frames/refresh`) and the
# Presentation render routes (`POST
# /api/presentation/components/{component_id}/revisions/{revision}/render` and
# its `/render/data` export), which compare the `x-dfo-principal` header
# against it. On the dfo-ai side it gates `POST /api/studio/refresh`, which
# takes it as `Authorization: Bearer <value>`. The website holds the value and
# sends it server-side on both calls. Unset or empty, every one of those
# routes refuses, and the website offers no Live Data option on a share.
# It is a separate value from `datasets_first_party_principal.tf`'s and
# `datasets_pin_principal.tf`'s, and from the ai stack's `STUDIO_API_TOKEN`.
# The refresh routes rebuild frames and render cards on a caller's behalf and
# publish or pin nothing, a narrower grant than either door, and the
# allowlists have to be free to rotate independently.
# This carries the same interim caveat as the other principals: the `apis`
# service has `allUsers` as an invoker with no proxy validating the caller, so
# an internet caller who learns this value reaches the refresh routes. A
# generated secret keeps the value hard to guess on the first try and leaves
# the exposure in place.
# This stack applies before `ai` and `website`, which `apply.yml` does by
# listing it as a producer stack. Both read the secret by id, and a revision
# that mounts a secret that does not exist yet fails to start.

locals {
  # Single counter for the write-only pair below. The ephemeral value
  # regenerates every plan but only reaches the secret version when this
  # number changes. Bump it to rotate.
  live_refresh_principal_version = 1
}

# Alphanumeric only, so the value drops into the `x-dfo-principal` header, a
# bearer token, a curl command, or an env file with no escaping anywhere.
ephemeral "random_password" "live_refresh_principal" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "live_refresh_principal" {
  secret_id = "${var.namespace}-live-refresh-principal"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "live_refresh_principal" {
  secret                 = google_secret_manager_secret.live_refresh_principal.id
  secret_data_wo         = ephemeral.random_password.live_refresh_principal.result
  secret_data_wo_version = local.live_refresh_principal_version

  lifecycle {
    # A counter bump replaces this resource, and the replacement must exist
    # before the old version is destroyed so this stack's own pinned
    # reference never points at nothing.
    create_before_destroy = true
  }
}

# Humans who need to read the value directly (to call a refresh route from a
# laptop against deployed dev, or to configure a local `.env` that points at
# deployed dev) read it from Secret Manager, and each grant is scoped to this
# one secret. Empty by default, because this stack mounts it directly (in
# main.tf) and the `ai` and `website` stacks' services carry it through their
# own `secret_env_vars` grants, so no human needs read access until one does.
resource "google_secret_manager_secret_iam_member" "live_refresh_principal_readers" {
  for_each  = toset(var.live_refresh_principal_readers)
  secret_id = google_secret_manager_secret.live_refresh_principal.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}
