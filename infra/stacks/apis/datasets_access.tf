# The Datasets API's access to its own storage and database. The buckets and
# the database themselves are declared in the `dcp` stack, alongside its
# garbage-collection identity — see that stack's `dfo_datasets.tf`. What
# follows here is scoped to the identity that actually runs the service:
# `module.apis_service.runtime_service_account_email`. A grant lives with the
# identity it empowers, so these grants sit in this stack next to the
# runtime account they name, not in `dcp` where the bucket and database
# resources themselves are declared.

# ─────────────────────────────────────────────────────────────────────────────
# Bucket access
# ─────────────────────────────────────────────────────────────────────────────

# Bucket-scoped grants, not project-wide. The runtime identity writes
# artifacts to the working bucket and reads them back, and promotion copies a
# working object into the pinned bucket — neither path deletes, so there is no
# storage.objectAdmin here. The delete permission lives only with the
# garbage-collection identity in `dcp`.
resource "google_storage_bucket_iam_member" "datasets_working_creator" {
  bucket = var.datasets_working_bucket_name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}

resource "google_storage_bucket_iam_member" "datasets_working_viewer" {
  bucket = var.datasets_working_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}

resource "google_storage_bucket_iam_member" "datasets_pinned_creator" {
  bucket = var.datasets_pinned_bucket_name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}

resource "google_storage_bucket_iam_member" "datasets_pinned_viewer" {
  bucket = var.datasets_pinned_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# URL signing
# ─────────────────────────────────────────────────────────────────────────────

# A Cloud Run service account has no downloadable private key, so V4 signed
# URLs are produced through the IAM signBlob API instead of local key
# material. That path needs roles/iam.serviceAccountTokenCreator granted to
# the runtime identity on itself — a service-account-level IAM member where
# the account is both the resource being granted on and the member receiving
# the grant.
#
# V4 signed URLs cap out at 7 days from the moment they're signed; the
# Datasets API's signed-URL TTL cannot exceed that ceiling.
#
# service_account_id is built from the module's own output rather than a
# hand-built naming convention: the module truncates the account id to 30
# characters, so an email assembled from `service_name` elsewhere could
# silently name the wrong account.
resource "google_service_account_iam_member" "datasets_token_creator" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${module.apis_service.runtime_service_account_email}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Cloud SQL IAM access
# ─────────────────────────────────────────────────────────────────────────────

# roles/cloudsql.client is what lets the runtime identity open a connection
# to the instance at all; cloudsql.instances.login is what then lets an IAM
# database login succeed once connected — the google_sql_user below only
# creates the Postgres-side role that login maps to, it grants neither
# permission itself. Both are project-scoped rather than narrower: the
# instance authorises per project (platform's allowed_consumer_projects), not
# per consumer, so there is no finer grain to grant these two roles at while
# every stack here shares one project. Nothing wider — no
# cloudsql.editor, no cloudsql.admin.
resource "google_project_iam_member" "datasets_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}

# roles/cloudsql.instanceUser carries cloudsql.instances.login (needed) and
# cloudsql.instances.get, but also cloudsql.instances.executeSql — the
# permission behind the Cloud SQL Data API, which runs arbitrary SQL against
# the instance over its Admin API rather than the PSC network path this
# service's grants otherwise assume. This service is public and
# unauthenticated and reads untrusted input into an LLM client, so that
# permission would hand it a second route to the database that bypasses the
# PSC boundary entirely. A custom role carries login and get without it.
resource "google_project_iam_custom_role" "cloudsql_login_only" {
  project     = var.project_id
  role_id     = var.cloudsql_login_role_id
  title       = "Cloud SQL IAM login without Data API execute"
  description = "cloudsql.instances.login and cloudsql.instances.get, without cloudsql.instances.executeSql."
  permissions = [
    "cloudsql.instances.login",
    "cloudsql.instances.get",
  ]
}

resource "google_project_iam_member" "datasets_cloudsql_instance_user" {
  project = var.project_id
  role    = google_project_iam_custom_role.cloudsql_login_only.id
  member  = "serviceAccount:${module.apis_service.runtime_service_account_email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Database user
# ─────────────────────────────────────────────────────────────────────────────

# Runtime user: the service's own identity, authenticating over IAM rather
# than a stored password, so it connects as itself with no password to store
# or rotate. For Postgres, Cloud SQL derives the database username from the
# service account email with the ".gserviceaccount.com" suffix trimmed off,
# since the full email overflows Postgres's username length limit.
#
# Migrations (owning repo, out of scope here) grant this user privileges
# against schema objects, so it may end up owning things Postgres won't let a
# plain DROP USER touch. ABANDON drops it from Terraform state without
# attempting the API delete on a destroy, which is the provider's own
# guidance for a Postgres user carrying granted SQL roles.
resource "google_sql_user" "datasets_runtime" {
  name     = trimsuffix(module.apis_service.runtime_service_account_email, ".gserviceaccount.com")
  instance = var.platform_postgres_instance_name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"

  deletion_policy = "ABANDON"
}

# CONNECT on the two databases this user serves. The `dcp` stack creates both
# databases and revokes PUBLIC's default CONNECT on each. The grant lives
# here, next to the role it names, so dcp applies before this stack on an
# empty project. REVOKE ... FROM PUBLIC leaves an explicit grant in place, so
# a re-run of either stack's script leaves the other's result alone. The
# datasets worker's runtime user inherits this CONNECT through its membership
# in this role (datasets_worker.tf). The script connects to "postgres" for
# the reason dcp's dfo_datasets.tf gives: pg_database is a cluster-wide
# catalog, and the session must not depend on a grant the scripts edit.
resource "google_sql_provision_script" "runtime_connect" {
  project     = var.project_id
  instance    = var.platform_postgres_instance_name
  database    = "postgres"
  description = "Grants the apis runtime user CONNECT on the datasets and presentation databases."

  script = <<-SQL
    GRANT CONNECT ON DATABASE "${var.datasets_database_name}" TO "${google_sql_user.datasets_runtime.name}";
    GRANT CONNECT ON DATABASE "${var.presentation_database_name}" TO "${google_sql_user.datasets_runtime.name}";
  SQL
}

output "datasets_runtime_db_user" {
  description = "Cloud SQL username of the runtime, IAM-authenticated database user (DML only, granted by the owning repo's migrations, not by this stack)."
  value       = google_sql_user.datasets_runtime.name
}

# ─────────────────────────────────────────────────────────────────────────────
# Migration runner identity
# ─────────────────────────────────────────────────────────────────────────────

# A dedicated identity, distinct from module.apis_service.runtime_service_account_email.
# The runtime identity serves a public, unauthenticated surface that reads
# untrusted input into an LLM client. The migrator Postgres user is BUILT_IN,
# and Cloud SQL auto-grants BUILT_IN users cloudsqlsuperuser, which reaches
# every database on the shared instance rather than staying scoped to
# datasets the way the login-only custom role above scopes the runtime
# identity's own access. Handing the serving identity a DDL-capable,
# instance-wide credential is the blast radius this separation avoids.
resource "google_service_account" "datasets_migration_runner" {
  project      = var.project_id
  account_id   = "${var.namespace}-migration-runner"
  display_name = "Datasets API Cloud SQL migration runner"
}

# Scoped to the one secret the runner needs, not a project-level grant. The
# runner reaches the instance over plain TCP at its PSC endpoint address and
# authenticates as the migrator user with this password, so it takes no
# Cloud SQL IAM role here: no roles/cloudsql.client, no login role, and no
# google_sql_user, since it never opens a connector session or does an IAM
# database login. The migrator Postgres user itself is declared in the `dcp`
# stack, alongside the secret this grant reads.
resource "google_secret_manager_secret_iam_member" "datasets_migrator_secret_reader" {
  secret_id = var.datasets_migrator_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.datasets_migration_runner.email}"
}

# actAs on the migration-runner identity for the dfo-apis image-deployer, the
# same actAs the runtime identity already grants it above. Without this a
# deploy pipeline can create the account's Cloud Run Job but cannot attach
# this identity to it.
resource "google_service_account_iam_member" "datasets_migration_runner_deployer_act_as" {
  service_account_id = google_service_account.datasets_migration_runner.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${data.google_service_account.apis_deployer.email}"
}

output "datasets_migration_runner_service_account_email" {
  description = "Email of the dedicated migration-runner service account. It holds no Cloud SQL IAM role: it authenticates to Postgres as the BUILT_IN migrator user over the PSC network path, not through the Cloud SQL connector."
  value       = google_service_account.datasets_migration_runner.email
}
