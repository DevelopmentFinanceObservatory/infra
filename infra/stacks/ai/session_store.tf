# The harness's ADK session store, a database on the shared Cloud SQL
# instance from the `platform` stack, holds every conversation
# `DatabaseSessionService` persists so an instance replacement does not lose
# it. ADK owns its schema end to end. `prepare_tables` runs SQLAlchemy
# `create_all` over the same connection the service reads and writes with.
# The one identity serves the harness and creates its own tables, unlike
# `datasets_access.tf`'s split between a runtime and a migration runner, and
# nothing else lands in this database, which keeps that safe.

resource "google_sql_database" "ai_sessions" {
  name     = "ai-sessions"
  instance = var.platform_postgres_instance_name
}

# The runtime user is the service's own identity, authenticating over IAM
# rather than a stored password, so it connects as itself with no password
# to store or rotate. A `BUILT_IN` user would carry Cloud SQL's auto-granted,
# instance-wide `cloudsqlsuperuser`, the blast radius `datasets_access.tf`
# avoids by splitting off a separate migrator identity. This service is
# public, unauthenticated, and reads untrusted input into an LLM client,
# which rules out a migrator identity to grant that role to instead. Cloud
# SQL derives the database username from the service account email with the
# ".gserviceaccount.com" suffix trimmed off, since the full email overflows
# Postgres's username length limit.
resource "google_sql_user" "ai_sessions_runtime" {
  name     = trimsuffix(module.ai_service.runtime_service_account_email, ".gserviceaccount.com")
  instance = var.platform_postgres_instance_name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"

  # ADK's own `create_all` grants this user ownership of the tables it
  # creates, so it may end up owning schema objects a plain DROP USER can't
  # clear on its own. ABANDON drops it from Terraform state without
  # attempting the API delete on a destroy, the provider's own guidance for
  # a Postgres user carrying granted SQL roles.
  deletion_policy = "ABANDON"
}

# roles/cloudsql.client is what lets the runtime identity open a connection
# to the instance at all. cloudsql.instances.login then lets an IAM database
# login succeed once connected. The google_sql_user above only creates the
# Postgres-side role that login maps to, and grants neither permission
# itself. Both are project-scoped. The instance authorises per project
# (platform's allowed_consumer_projects) rather than per consumer, the
# finest grain available while every stack here shares one project.
# Nothing wider: no cloudsql.editor, no cloudsql.admin.
resource "google_project_iam_member" "ai_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${module.ai_service.runtime_service_account_email}"
}

# roles/cloudsql.instanceUser carries cloudsql.instances.login (needed) and
# cloudsql.instances.get, but also cloudsql.instances.executeSql, the
# permission behind the Cloud SQL Data API, which runs arbitrary SQL against
# the instance over its Admin API rather than the PSC network path this
# service's grants otherwise assume. This service is public and
# unauthenticated and reads untrusted input into an LLM client, so that
# permission would hand it a second route to the database that bypasses the
# PSC boundary entirely. A custom role carries login and get without it. The
# stack defines its own copy rather than referencing `apis`' or `website`'s
# role, so neither other stack's teardown can break this one's logins.
resource "google_project_iam_custom_role" "cloudsql_login_only" {
  project     = var.project_id
  role_id     = var.cloudsql_login_role_id
  title       = "Cloud SQL IAM login without Data API execute (ai)"
  description = "cloudsql.instances.login and cloudsql.instances.get, without cloudsql.instances.executeSql."
  permissions = [
    "cloudsql.instances.login",
    "cloudsql.instances.get",
  ]
}

resource "google_project_iam_member" "ai_cloudsql_login" {
  project = var.project_id
  role    = google_project_iam_custom_role.cloudsql_login_only.id
  member  = "serviceAccount:${module.ai_service.runtime_service_account_email}"
}

# A new Postgres database starts with CONNECT granted to PUBLIC, the
# cluster-wide default ACL a CREATE DATABASE gets unless something revokes
# it, so any role on this shared instance can connect here unless that
# default is revoked. `database` below is "postgres" rather than
# "ai-sessions". REVOKE/GRANT ON DATABASE edits a row in the cluster-wide
# pg_database catalog, so the script runs from any database on the instance
# the caller can reach, including on a re-run after PUBLIC has already lost
# CONNECT on "ai-sessions" itself. GRANT runs before REVOKE, the order the
# `website` stack's own database ACL script uses. The first statement to
# touch a NULL datacl materialises the default ACL, and a partial failure
# must not leave anything locked out. The platform stack revokes PUBLIC's
# own CONNECT on "postgres" and grants the applier CONNECT there explicitly,
# which keeps this script re-runnable.
resource "google_sql_provision_script" "ai_sessions_revoke_public_connect" {
  project     = var.project_id
  instance    = var.platform_postgres_instance_name
  database    = "postgres"
  description = "Grants CONNECT on the ai-sessions database to the runtime user, then revokes PUBLIC's default CONNECT."

  script = <<-SQL
    GRANT CONNECT ON DATABASE "${google_sql_database.ai_sessions.name}" TO "${google_sql_user.ai_sessions_runtime.name}";
    REVOKE CONNECT ON DATABASE "${google_sql_database.ai_sessions.name}" FROM PUBLIC;
  SQL
}

# Schema-level grant. CREATE ON SCHEMA is a per-database privilege, unlike
# the CONNECT ACL above, which lives in the cluster-wide pg_database catalog
# and can be edited from any database on the instance. This script connects
# to its own database instead, since there is no shared catalog row to edit
# here, only this database's own public schema. The applier needs no new
# grant to run this. Cloud SQL Admin API databases are owned by
# cloudsqlsuperuser, and membership in a database's owner role carries
# pg_database_owner in that database, which is what GRANT ON SCHEMA public
# requires.
#
# CREATE is what ADK's `prepare_tables` needs. It runs SQLAlchemy
# `create_all` over this connection on every startup, and Postgres grants no
# CREATE on the public schema to PUBLIC. USAGE is stated here explicitly,
# the same reason the `website` stack's schema grant states its own USAGE
# explicitly. Any future tightening of PUBLIC's schema privileges must not
# cut this runtime user off along with everyone else.
resource "google_sql_provision_script" "ai_sessions_schema_grant" {
  project     = var.project_id
  instance    = var.platform_postgres_instance_name
  database    = google_sql_database.ai_sessions.name
  description = "Grants the runtime user USAGE and CREATE on the public schema of the ai-sessions database, so ADK's own create_all can build its tables there."

  script = <<-SQL
    GRANT USAGE ON SCHEMA public TO "${google_sql_user.ai_sessions_runtime.name}";
    GRANT CREATE ON SCHEMA public TO "${google_sql_user.ai_sessions_runtime.name}";
  SQL
}
