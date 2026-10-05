# Presentation API infrastructure — kept in its own file for the same reason
# as dfo_datasets.tf: main.tf, variables.tf, outputs.tf, terraform.tfvars,
# backend.tf, and README.md are all rewritten byte-for-byte by `datacommons
# admin init --force`, so any DFO logic placed in them would be silently
# clobbered on the next regen.
#
# This file holds the Presentation API's database and migrator user on the
# shared Cloud SQL instance from the `platform` stack — the same instance
# `dfo_datasets.tf` already uses, referenced through that file's
# `platform_postgres_instance_name` variable rather than redeclaring it here. Presentation owns no buckets and no
# garbage-collection identity: `presentation_api.config.PresentationSettings`
# delegates to `datasets_api.config.DatasetsSettings` for graph, SDMX, and
# artifact-bucket configuration, so there is nothing new to provision on that
# side. The serving identity's own access — its runtime database user — is
# the *same* `google_sql_user.datasets_runtime` the Datasets API already
# uses, declared in the `apis` stack, which also grants it CONNECT on this
# database. Its schema-level grants come from the owning repo's migrations.

# ─────────────────────────────────────────────────────────────────────────────
# Variables
# ─────────────────────────────────────────────────────────────────────────────

variable "presentation_database_name" {
  description = "Name of the Presentation API's database inside the shared Cloud SQL instance. A separate database from `datasets`, not a second schema inside it — holds the composition, component, and draft-lease tables presentation_store.migrate applies."
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# Database
# ─────────────────────────────────────────────────────────────────────────────

# Against the shared instance from the `platform` stack, referenced by the
# same plain-value variable dfo_datasets.tf uses. A Cloud SQL Admin API
# operation, not a network one, so it needs no VPC connectivity to the
# instance.
#
# check-destroys.sh already treats google_sql_database as a protected type
# (destroy/replace fails a plan in CI), so no lifecycle block is needed here
# on top of that.
resource "google_sql_database" "presentation" {
  name     = var.presentation_database_name
  instance = var.platform_postgres_instance_name
}

# Same PUBLIC-CONNECT revoke dfo_datasets.tf's own provision script performs,
# for the same reason: a new Postgres database starts with CONNECT granted to
# PUBLIC, so every database on the instance needs its own explicit revoke.
# Connects to "postgres" rather than "presentation" for the same re-runnable
# reason dfo_datasets.tf's script documents — REVOKE/GRANT ON DATABASE edits
# the cluster-wide pg_database catalog, not something scoped to a session on
# the target database.
#
# Only the migrator declared below gets CONNECT back here. The shared
# runtime user gets it from the `apis` stack's
# google_sql_provision_script.runtime_connect, which the revoke leaves in
# place. There is no garbage-collection identity to grant here, since
# Presentation has none.
resource "google_sql_provision_script" "presentation_revoke_public_connect" {
  project     = var.project_id
  instance    = var.platform_postgres_instance_name
  database    = "postgres"
  description = "Revokes PUBLIC's default CONNECT on the presentation database, granting it back to that database's own migrator."

  script = <<-SQL
    REVOKE CONNECT ON DATABASE "${google_sql_database.presentation.name}" FROM PUBLIC;
    GRANT CONNECT ON DATABASE "${google_sql_database.presentation.name}" TO "${google_sql_user.presentation_migrator.name}";
  SQL
}

# ─────────────────────────────────────────────────────────────────────────────
# Database user
#
# The migrator user, authenticating with a built-in password and holding DDL,
# mirroring dfo_datasets.tf's datasets_migrator exactly. A dedicated role
# rather than reusing datasets_migrator: presentation_store.migrate reads a
# distinct PRESENTATION_STORE_MIGRATOR_* env-var family end to end, and
# keeping the role per-tenant preserves the isolation the existing design
# deliberately keeps, even though a BUILT_IN role's cloudsqlsuperuser grant
# is instance-wide either way. The runtime user needs no counterpart here —
# it's declared once, in the `apis` stack, and shared across every tenant
# database on the instance.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # The Secret Manager version and SQL user share this write-only counter. A
  # partial apply can write one resource and fail on the other. Applying again
  # with the same counter generates a fresh password and sends it to the
  # resource that failed. The secret and SQL user then hold different
  # passwords. Increment `presentation_migrator_password_version` in a PR.
  # After it merges, CI applies the whole dcp stack and sends one fresh
  # password to both resources.
  presentation_migrator_password_version = 1
}

ephemeral "random_password" "presentation_migrator" {
  length  = 32
  special = true
  # Same trimmed special charset as datasets_migrator: the provider's default
  # includes "@", "#", ":" and "?", each of which needs escaping inside a
  # Postgres connection string or a shell-quoted argument.
  override_special = "!$%^&*()-_=+[]{}<>"
}

# check-destroys.sh protects google_secret_manager_secret the same way it
# protects the database above, so this leans on the guard rather than a
# prevent_destroy lifecycle block. The password is regenerable, so blocking a
# pre-release teardown here would buy little.
resource "google_secret_manager_secret" "presentation_migrator_password" {
  secret_id = "${var.namespace}-presentation-migrator-password"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "presentation_migrator_password" {
  secret                 = google_secret_manager_secret.presentation_migrator_password.id
  secret_data_wo         = ephemeral.random_password.presentation_migrator.result
  secret_data_wo_version = local.presentation_migrator_password_version
}

resource "google_sql_user" "presentation_migrator" {
  name                = "${var.namespace}-presentation-migrator"
  instance            = var.platform_postgres_instance_name
  type                = "BUILT_IN"
  password_wo         = ephemeral.random_password.presentation_migrator.result
  password_wo_version = local.presentation_migrator_password_version

  # Migrations grant this user DDL, so it may end up owning schema objects a
  # plain DROP USER can't clear on its own. ABANDON drops it from Terraform
  # state without attempting the API delete on a destroy, which is the
  # provider's own guidance for a Postgres user carrying granted SQL roles.
  deletion_policy = "ABANDON"
}

# ─────────────────────────────────────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────────────────────────────────────

# Connection facts for whoever runs the presentation migrations. The instance
# connection name is not republished here — it's the same instance
# dfo_datasets.tf already publishes as `datasets_instance_connection_name`.
# The runtime database username is likewise not among these — it names the
# serving identity declared in the `apis` stack, published from that stack's
# outputs.

output "presentation_database_name" {
  description = "Name of the Presentation API's database on the shared Cloud SQL instance."
  value       = google_sql_database.presentation.name
}

output "presentation_migrator_secret_id" {
  description = "Fully-qualified Secret Manager id (projects/.../secrets/...) of the secret holding the presentation migrator user's built-in password. No reader is granted on it by this stack. The migration runner's read access is a later decision."
  value       = google_secret_manager_secret.presentation_migrator_password.id
}

output "presentation_migrator_secret_name" {
  description = "Short Secret Manager secret_id of the presentation migrator password secret, for `gcloud secrets versions access latest --secret=<this>`."
  value       = google_secret_manager_secret.presentation_migrator_password.secret_id
}
