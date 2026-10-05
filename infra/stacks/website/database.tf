# The website's tenant database on the shared Cloud SQL instance from the platform stack: accounts, saved views, share links.
# ADK agent sessions deliberately live in the ai stack's own tenant database (#155), because ADK creates its own tables over whatever connection it gets, and the website runtime should hold DML only.
# Same instance, so creating this database is a namespace, not new spend.

locals {
  website_runtime_member = "serviceAccount:${module.website_service.runtime_service_account_email}"
}

resource "google_sql_database" "website" {
  name     = "website${local.tier_suffix}"
  instance = var.platform_postgres_instance_name
}

# The runtime user, IAM-authenticated as the service's own runtime identity, so it holds no password.
# Named via trimsuffix off the module output rather than a copied string, keeping the Postgres role tied to the service account resource (Cloud SQL rejects an IAM user whose backing account does not exist, so the dependency has to be real).
# Runtime service account IDs are operationally fixed. Renaming one creates a new Cloud SQL role while existing table and sequence ACLs and future default grants remain attached to the old role. A rename needs a separate, live-tested rotation.
resource "google_sql_user" "website_runtime" {
  name     = trimsuffix(module.website_service.runtime_service_account_email, ".gserviceaccount.com")
  instance = var.platform_postgres_instance_name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"

  deletion_policy = "ABANDON"
}

# The IAM half of runtime authentication. The google_sql_user resources above only create the Postgres-side role a login maps to.
# roles/cloudsql.client lets each runtime identity open a connection to the instance, and cloudsql.instances.login is what then lets the IAM login succeed.
# Project-scoped for the same reason as the apis grants: the instance authorises per project, so there is no finer grain while every stack shares one project.
resource "google_project_iam_member" "website_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = local.website_runtime_member
}

# Same reasoning as apis' cloudsql_login_only role, which applies here verbatim: roles/cloudsql.instanceUser would carry cloudsql.instances.executeSql, the Data API permission that bypasses the PSC boundary entirely, and the website service is public and unauthenticated.
# The stack defines its own copy rather than referencing the apis stack's role so neither stack's teardown can break the other's logins.
resource "google_project_iam_custom_role" "cloudsql_login_only" {
  project     = var.project_id
  role_id     = var.cloudsql_login_role_id
  title       = "Cloud SQL IAM login without Data API execute (website)"
  description = "cloudsql.instances.login and cloudsql.instances.get, without cloudsql.instances.executeSql."
  permissions = [
    "cloudsql.instances.login",
    "cloudsql.instances.get",
  ]
}

resource "google_project_iam_member" "website_cloudsql_login" {
  project = var.project_id
  role    = google_project_iam_custom_role.cloudsql_login_only.id
  member  = local.website_runtime_member
}

# A migrator identity, distinct from the runtime identity above. A Job's target database is
# only an env var its container reads, so the identity is the real isolation boundary between
# what the runtime, DML-only identity can reach and what a migration can do. The migrator is an
# IAM service account, so it carries no password and starts with no privileges. A BUILT_IN user
# auto-carries instance-wide cloudsqlsuperuser instead. Terraform grants the migrator only what
# its own database needs.
#
# The migrator holds database-level CREATE, not just schema-level CREATE. drizzle-orm's
# stock migrate() always issues CREATE SCHEMA IF NOT EXISTS, and Postgres checks database
# CREATE before that existence check runs, so schema CREATE alone fails even though the
# target schema (here, public) already exists. Database CREATE lets a role create schemas
# and install trusted extensions, carries no ownership (no DROP DATABASE, no ALTER DATABASE),
# reaches no other tenant's database, and does not itself include schema CREATE, so the
# explicit grant on the public schema below still applies.
#
# db/migrations/0000_bootstrap_grants.sql's ALTER DEFAULT PRIVILEGES for the
# TABLE and SEQUENCE grants only reaches IN SCHEMA public, so a later migration's new schema
# needs its own default-privileges grant, or the runtime user gets nothing on its tables.
# The one exception is the routine-execute revoke from PUBLIC that migration also issues:
# that statement carries no IN SCHEMA clause at all, deliberately, so it already reaches every
# schema the migrator ever creates and does not need repeating per schema.
#
# The tier is abbreviated (local.tier_suffix_short) because account_id is capped at 30
# characters (infra/modules/cloud-run-service/main.tf already defends against this with a
# substr): "dfo-dev-website-staging-migrator" would be 32, so dev uses "dfo-dev-website-stg-migrator"
# (28). Production carries no tier, giving "dfo-prod-website-migrator" (25).
resource "google_service_account" "website_migrator" {
  account_id   = "${var.namespace}-website${local.tier_suffix_short}-migrator"
  display_name = "Website database migrator (${var.tier})"
}

resource "google_sql_user" "website_migrator" {
  name     = trimsuffix(google_service_account.website_migrator.email, ".gserviceaccount.com")
  instance = var.platform_postgres_instance_name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"

  deletion_policy = "ABANDON"
}

# Each migrator's own project IAM. Both roles gate the login itself, ahead of the DDL that follows: roles/cloudsql.client carries cloudsql.instances.connect, which is what lets the connector fetch instance metadata and an ephemeral certificate over the Admin API before any connection exists. cloudsql_login_only then gates the Postgres-side login once that connection is up.
# A role holding only login and get, without client, fails before it ever reaches the database, so each migrator needs both, the same pairing the runtime identities hold above.
resource "google_project_iam_member" "website_migrator_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.website_migrator.email}"
}

resource "google_project_iam_member" "website_migrator_cloudsql_login" {
  project = var.project_id
  role    = google_project_iam_custom_role.cloudsql_login_only.id
  member  = "serviceAccount:${google_service_account.website_migrator.email}"
}

# The website database's ACL. The runtime user and migrator get CONNECT on the database only,
# and the migrator also gets CREATE on it, the reasoning is above the migrator resources.
# GRANT before REVOKE for the same reason as the platform stack's postgres_revoke_public_connect: the first statement to touch a NULL datacl materializes the default ACL, and stopping after a partial failure must leave nothing locked out.
# The script connects to `postgres` rather than to the database it edits, dcp's shape: if the session depended on the grant the script revokes, a later re-run after PUBLIC loses CONNECT would have no way back in, and pg_database is a shared catalog so the statements work from any database.
resource "google_sql_provision_script" "website_db_acl" {
  project     = var.project_id
  instance    = var.platform_postgres_instance_name
  database    = "postgres"
  description = "Grants CONNECT on the ${google_sql_database.website.name} database to the ${var.tier} runtime user and the ${var.tier} migrator, CREATE on the database to the ${var.tier} migrator, then revokes PUBLIC's default CONNECT."

  script = <<-SQL
    GRANT CONNECT ON DATABASE "${google_sql_database.website.name}" TO "${google_sql_user.website_runtime.name}";
    GRANT CONNECT ON DATABASE "${google_sql_database.website.name}" TO "${google_sql_user.website_migrator.name}";
    GRANT CREATE ON DATABASE "${google_sql_database.website.name}" TO "${google_sql_user.website_migrator.name}";
    REVOKE CONNECT ON DATABASE "${google_sql_database.website.name}" FROM PUBLIC;
  SQL
}

# Schema-level grant. CREATE ON SCHEMA is a per-database privilege, unlike the CONNECT ACL above, which lives in the cluster-wide pg_database catalog and can be edited from any database on the instance.
# This script connects to its own database rather than to `postgres` for exactly that reason: there is no shared catalog row to edit here, only this database's own public schema.
# The applier needs no new grant to run this. Cloud SQL Admin API databases are owned by cloudsqlsuperuser, the applier already holds that role, and membership in a database's owner role carries pg_database_owner in that database, which is what GRANT ON SCHEMA public requires.
#
# USAGE ON SCHEMA public for both roles lives here rather than in the app's migration, for the same reason CREATE does not: the migrator issuing `GRANT USAGE ON SCHEMA public TO <runtime>` itself is a no-op. It holds CREATE ON SCHEMA (granted below) but not ownership or grant option, so Postgres emits `WARNING: no privileges were granted for "public"` and the schema's ACL is unchanged; only the applier's pg_database_owner membership can actually grant it. Both the runtime user and the migrator get it explicitly: today both derive USAGE solely from PUBLIC's default, and granting only the runtime here would leave the migrator dependent on that default alone, so any future tightening of PUBLIC's schema privileges would cut the migrator off along with everyone else.
resource "google_sql_provision_script" "website_db_schema_grant" {
  project     = var.project_id
  instance    = var.platform_postgres_instance_name
  database    = google_sql_database.website.name
  description = "Grants the ${var.tier} migrator CREATE on the public schema of the ${google_sql_database.website.name} database, and USAGE on that schema to both the ${var.tier} migrator and the ${var.tier} runtime user."

  script = <<-SQL
    GRANT CREATE ON SCHEMA public TO "${google_sql_user.website_migrator.name}";
    GRANT USAGE ON SCHEMA public TO "${google_sql_user.website_migrator.name}";
    GRANT USAGE ON SCHEMA public TO "${google_sql_user.website_runtime.name}";
  SQL
}
