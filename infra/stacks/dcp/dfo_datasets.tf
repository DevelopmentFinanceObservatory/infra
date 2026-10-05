# Datasets API infrastructure — kept in this separate file for the same reason
# as dfo.tf: main.tf, variables.tf, outputs.tf, terraform.tfvars, backend.tf,
# and README.md are all rewritten byte-for-byte by `datacommons admin init
# --force` and never scanned for other files, so any DFO logic placed in them
# would be silently clobbered on the next regen. Terraform does not care which
# file a `variable`/`resource`/`output` block lives in, so this file declares
# its own variables and outputs alongside the resources rather than adding
# them to variables.tf/outputs.tf (see dfo.README.md).
#
# This file holds the Datasets API's GCS artifact buckets, the
# garbage-collection identity that reclaims objects from the pinned one, and
# its database and migrator user on the shared Cloud SQL instance from the
# `platform` stack. The serving identity's own access — the bucket grants it
# reads and writes through, the signed-URL signing setup, and its runtime
# database user — lives in the `apis` stack, next to the Cloud Run service
# that runs as that identity: a grant lives with the identity it empowers.

# Write-only arguments (the migrator password below) are a Terraform-core
# feature, not a provider one, so the floor belongs here rather than in
# dfo_override.tf's required_providers bump. main.tf has no required_version
# block at all to override or conflict with, so this is a plain addition, not
# a merge — see dfo_override.tf for why the provider floors need the override
# trick instead.
terraform {
  required_version = ">= 1.11"
}

# ─────────────────────────────────────────────────────────────────────────────
# Variables
# ─────────────────────────────────────────────────────────────────────────────

variable "datasets_working_bucket_name" {
  description = "Name of the GCS bucket the Datasets API writes to while a dataset build is in progress. Objects here are transient (content-addressed by digest, superseded by every re-run) and are deleted automatically after a short retention window — see the lifecycle_rule on the bucket resource below."
  type        = string
}

variable "datasets_pinned_bucket_name" {
  description = "Name of the GCS bucket that holds published dataset artifacts referenced by digest. Objects here are permanent until reclaimed by a future quarterly garbage-collection job that walks references elsewhere in the system; nothing here deletes them on a timer."
  type        = string
}

variable "datasets_cors_origins" {
  description = "Origins allowed to read cross-origin responses from signed URLs against the Datasets buckets (the CORS `origin` allowlist on both buckets). Must include every site origin that fetches dataset files directly from GCS via a signed URL."
  type        = list(string)
}

variable "platform_postgres_instance_name" {
  description = "Name of the shared Cloud SQL instance from the `platform` stack, e.g. \"dfo-dev-platform-postgres\". A plain value copied from that stack's `instance_name` output into dfo.auto.tfvars, not read via terraform_remote_state, so this stack's plan never depends on platform having applied. A database resource only needs the instance name, which is why it lives in this stack rather than platform's."
  type        = string
}

variable "platform_postgres_connection_name" {
  description = "Cloud SQL connection name (project:region:instance) of the shared instance from the `platform` stack, copied from that stack's `connection_name` output. Published again below as a dcp output so whoever runs the datasets migrations has it without cross-referencing the platform stack."
  type        = string
}

variable "datasets_database_name" {
  description = "Name of the Datasets API's database inside the shared Cloud SQL instance. Holds the spec registry, version records, artifact inventory, reference rows, revocation state and the append-only audit log."
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# Buckets
# ─────────────────────────────────────────────────────────────────────────────

# Working bucket: in-progress dataset build output. Churns constantly, so
# objects are deleted 30 days after creation and soft-delete is disabled
# (retention_duration_seconds = 0) — there is nothing worth recovering here,
# and paying for soft-deleted copies of transient objects is wasted spend.
resource "google_storage_bucket" "datasets_working" {
  name     = var.datasets_working_bucket_name
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  versioning {
    enabled = false
  }
  force_destroy = false

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

  # staging/ holds the uploads the Datasets API streams an artifact into
  # before copying it to its digest name (ArtifactStore.open_put). A copied
  # staging object is never read again and an abandoned one is never read at
  # all, so both are deleted after one day, the shortest age GCS supports.
  # The runtime identities hold no delete grant, so this rule is the only
  # cleanup.
  lifecycle_rule {
    condition {
      age            = 1
      matches_prefix = ["staging/"]
    }
    action {
      type = "Delete"
    }
  }

  soft_delete_policy {
    retention_duration_seconds = 0
  }

  cors {
    origin          = var.datasets_cors_origins
    method          = ["GET"]
    response_header = ["Content-Type", "Content-Length", "Content-Range", "Content-Disposition", "ETag"]
    max_age_seconds = 3600
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Pinned bucket: published dataset artifacts, referenced by digest elsewhere
# in the system. No age-based delete rule — objects live until a future
# quarterly GC job removes the ones nothing references anymore. Soft delete is
# on with the maximum 90-day window, as a safety net behind that not-yet-built
# GC job rather than behind routine object churn. Standard storage class
# (the default) — no SetStorageClass transitions, since access patterns for
# published datasets aren't cold-storage candidates.
resource "google_storage_bucket" "datasets_pinned" {
  name     = var.datasets_pinned_bucket_name
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  versioning {
    enabled = false
  }
  force_destroy = false

  soft_delete_policy {
    retention_duration_seconds = 7776000 # 90 days
  }

  cors {
    origin          = var.datasets_cors_origins
    method          = ["GET"]
    response_header = ["Content-Type", "Content-Length", "Content-Range", "Content-Disposition", "ETag"]
    max_age_seconds = 3600
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Garbage-collection identity
# ─────────────────────────────────────────────────────────────────────────────

# A separate identity from the serving one (declared in the `apis` stack).
# The ability to delete a pinned object is held only by the scheduled
# garbage-collection job. The serving identity only creates and reads. This
# identity also holds a database role, declared below alongside the rest of
# its grants, because deciding whether a pinned object is still referenced
# means reading the reference rows the serving identity writes.
resource "google_service_account" "datasets_gc" {
  account_id   = "${var.namespace}-dc-datasets-gc-sa"
  display_name = "Datasets API garbage-collection service account"
}

resource "google_storage_bucket_iam_member" "datasets_pinned_gc_admin" {
  bucket = google_storage_bucket.datasets_pinned.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.datasets_gc.email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Database
# ─────────────────────────────────────────────────────────────────────────────

# Against the shared instance from the `platform` stack, referenced by the
# plain-value variable above rather than that stack's state. This is a Cloud
# SQL Admin API operation, not a network one, so it needs no VPC connectivity
# to the instance, unlike a service actually querying it.
#
# check-destroys.sh already treats google_sql_database as a protected type
# (destroy/replace fails a plan in CI), so no lifecycle block is needed here
# on top of that.
resource "google_sql_database" "datasets" {
  name     = var.datasets_database_name
  instance = var.platform_postgres_instance_name
}

# A new Postgres database starts with CONNECT granted to PUBLIC, the
# cluster-wide default ACL a CREATE DATABASE gets unless something revokes it,
# so any role on this shared instance, including a future tenant's, could
# connect to this one unless that default is revoked here. A `template1`
# revoke does not make that the default for future databases, because CREATE
# DATABASE copies template1's contents rather than its pg_database ACL row,
# so a database made from a revoked template1 still starts with PUBLIC
# holding CONNECT. Every database on the instance needs its own explicit
# revoke, this one included.
#
# `database` below is "postgres" rather than "datasets", because REVOKE/GRANT
# ON DATABASE changes a row in the cluster-wide pg_database catalog rather
# than something scoped to a session on that database, so it can be run from
# any database on the instance the caller can already reach. Connecting here
# rather than to "datasets" matters for re-runs. This statement revokes
# PUBLIC's own connect grant, and if the script's own session depended on
# that same grant to open, the next apply, after PUBLIC no longer has it and
# neither does the caller, would have no way back in. "postgres" keeps that
# path open regardless of what this script does to datasets. The `platform`
# stack revokes PUBLIC's own CONNECT on "postgres" and grants the applier
# CONNECT there explicitly, which keeps this script re-runnable.
#
# The runtime roles get CONNECT from the `apis` stack's
# google_sql_provision_script.runtime_connect, next to the users it names, so
# this stack applies before apis on an empty project. The revoke below leaves
# that explicit grant in place, so neither stack's re-run undoes the other.
#
# The Cloud SQL Data API runs this as whatever identity calls it, which for
# every apply in this repo is dfo-infra-applier (see the `platform` stack's
# README for its Cloud SQL IAM database user and the Data API setting this
# needs). REVOKE and GRANT are both no-ops when they already hold, so
# re-running this script on an unchanged database does nothing. Whether that
# identity has enough Postgres privilege to run a REVOKE/GRANT on a database
# it doesn't own depends on `google_sql_user.applier`'s `cloudsqlsuperuser`
# role, granted in the `platform` stack. This script's first run either does
# what it says or fails outright with a permission error; it can't silently
# do less than it says.
resource "google_sql_provision_script" "datasets_revoke_public_connect" {
  project     = var.project_id
  instance    = var.platform_postgres_instance_name
  database    = "postgres"
  description = "Revokes PUBLIC's default CONNECT on the datasets database, granting it back to that database's own migrator and garbage-collection roles."

  script = <<-SQL
    REVOKE CONNECT ON DATABASE "${google_sql_database.datasets.name}" FROM PUBLIC;
    GRANT CONNECT ON DATABASE "${google_sql_database.datasets.name}" TO "${google_sql_user.datasets_migrator.name}";
    GRANT CONNECT ON DATABASE "${google_sql_database.datasets.name}" TO "${google_sql_user.datasets_gc.name}";
  SQL
}

# ─────────────────────────────────────────────────────────────────────────────
# Database users
#
# The migrator user, authenticating with a built-in password and holding DDL.
# The runtime user — authenticating over IAM as the Datasets API's serving
# identity, DML only — is declared in the `apis` stack next to that identity,
# for the same reason its bucket grants are. Terraform creates the migrator
# user here. It does not grant it anything: the grant list is a property of
# the schema, so DDL grants live in the owning repo's migrations, not in this
# stack.
# ─────────────────────────────────────────────────────────────────────────────

# Migrator user: built-in and password-authenticated. Built-in users stay for
# migrations, rather than giving migrations another IAM identity. The password
# is generated here and never hard-coded. Only the generated secret is
# committed. Who reads dfo-dev-datasets-migrator-password at migration time
# (the migration runner) is a later decision. This stack creates the secret
# and grants no reader on it.
#
# The password itself never touches Terraform state. An `ephemeral` resource
# (unlike the `random_password` managed resource it replaces) exists only for
# the duration of a single plan/apply — Terraform never writes its result to
# state or plan files — and both consumers below take it through a
# corresponding `_wo` (write-only) argument, which the provider nulls out
# before the response ever reaches Terraform. The two `_wo_version` fields
# are what actually gets stored in state; they're the only signal Terraform
# has that a write-only argument changed; the ephemeral value itself is
# generated fresh on every apply but only reaches the SQL user or the secret
# version when its paired version number changes. Both fields below share one
# counter. A partial apply can write the Secret Manager version or SQL user
# and fail on its pair. Applying again with the same counter generates a fresh
# password and sends it to the resource that failed. The secret and SQL user
# then hold different passwords. Increment `datasets_migrator_password_version`
# in a PR. After it merges, CI applies the whole dcp stack and sends one fresh
# password to both resources.
locals {
  datasets_migrator_password_version = 1
}

ephemeral "random_password" "datasets_migrator" {
  length  = 32
  special = true
  # The provider's default special charset includes "@", "#", ":" and "?",
  # each of which needs escaping inside a Postgres connection string or a
  # shell-quoted argument. Trimming them out lets the migration runner drop
  # the password straight into either without extra handling.
  override_special = "!$%^&*()-_=+[]{}<>"
}

# check-destroys.sh protects google_secret_manager_secret the same way it
# protects the database above, so this leans on the guard rather than a
# prevent_destroy lifecycle block. The password is regenerable, so blocking a
# pre-release teardown here would buy little.
resource "google_secret_manager_secret" "datasets_migrator_password" {
  secret_id = "${var.namespace}-datasets-migrator-password"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "datasets_migrator_password" {
  secret                 = google_secret_manager_secret.datasets_migrator_password.id
  secret_data_wo         = ephemeral.random_password.datasets_migrator.result
  secret_data_wo_version = local.datasets_migrator_password_version
}

resource "google_sql_user" "datasets_migrator" {
  name                = "${var.namespace}-datasets-migrator"
  instance            = var.platform_postgres_instance_name
  type                = "BUILT_IN"
  password_wo         = ephemeral.random_password.datasets_migrator.result
  password_wo_version = local.datasets_migrator_password_version

  # Migrations grant this user DDL, so it may end up owning schema objects a
  # plain DROP USER can't clear on its own. ABANDON drops it from Terraform
  # state without attempting the API delete on a destroy, which is the
  # provider's own guidance for a Postgres user carrying granted SQL roles.
  deletion_policy = "ABANDON"
}

# Garbage-collection user: IAM-authenticated as the datasets_gc service
# account above, matching how the runtime user in the `apis` stack
# authenticates. `name` is derived with `trimsuffix` rather than written out,
# for the same reason as that runtime user. It keeps the Postgres role tied
# to the service account resource instead of a copied string, and Cloud SQL
# rejects an IAM user whose backing service account doesn't exist yet, so the
# dependency has to be real. No `database_roles`. This user starts with no
# privileges at all, which is correct for an identity that can already delete
# every object in the pinned bucket.
resource "google_sql_user" "datasets_gc" {
  name     = trimsuffix(google_service_account.datasets_gc.email, ".gserviceaccount.com")
  instance = var.platform_postgres_instance_name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"

  # This user owns nothing, but privileges on the migrator-owned tables are
  # granted to it by a migration in the owning repo, and Postgres refuses to
  # drop a role while privileges depending on it still exist. ABANDON leaves
  # the role in place on a destroy rather than letting the API delete fail
  # the apply.
  deletion_policy = "ABANDON"
}

# ─────────────────────────────────────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────────────────────────────────────

output "datasets_working_bucket_name" {
  description = "Name of the Datasets API working bucket, for the service's environment configuration."
  value       = google_storage_bucket.datasets_working.name
}

output "datasets_pinned_bucket_name" {
  description = "Name of the Datasets API pinned bucket, for the service's environment configuration."
  value       = google_storage_bucket.datasets_pinned.name
}

output "datasets_gc_service_account_email" {
  description = "Email of the Datasets API garbage-collection service account, for the scheduled garbage-collection job to run as."
  value       = google_service_account.datasets_gc.email
}

output "datasets_gc_db_user" {
  description = "Cloud SQL username of the garbage-collection identity's IAM-authenticated database user. It holds CONNECT on the datasets database and nothing else. Schema and table privileges are granted by the owning repo's migrations, which need this value."
  value       = google_sql_user.datasets_gc.name
}

# Connection facts for whoever runs the datasets migrations. The instance
# connection name is republished here (it originates as the `platform`
# stack's own output). The runtime database username is not among them — it
# names the serving identity declared in the `apis` stack, so it's published
# from that stack's outputs instead.

output "datasets_database_name" {
  description = "Name of the Datasets API's database on the shared Cloud SQL instance."
  value       = google_sql_database.datasets.name
}

output "datasets_instance_connection_name" {
  description = "Cloud SQL connection name (project:region:instance) of the shared instance the datasets database lives on."
  value       = var.platform_postgres_connection_name
}

output "datasets_migrator_secret_id" {
  description = "Fully-qualified Secret Manager id (projects/.../secrets/...) of the secret holding the migrator user's built-in password. No reader is granted on it by this stack. The migration runner's read access is a later decision."
  value       = google_secret_manager_secret.datasets_migrator_password.id
}

output "datasets_migrator_secret_name" {
  description = "Short Secret Manager secret_id of the migrator password secret, for `gcloud secrets versions access latest --secret=<this>`."
  value       = google_secret_manager_secret.datasets_migrator_password.secret_id
}
