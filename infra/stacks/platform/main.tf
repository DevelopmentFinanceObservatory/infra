terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.11.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_project_service" "apis" {
  for_each = toset([
    "sqladmin.googleapis.com",
    "iamcredentials.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

# The dfo-infra-applier CI service account (provisioned in ../foundation) is
# what runs `terraform apply` for every stack, including the provision
# scripts each tenant stack declares against its own database over the Cloud
# SQL Data API. A provision script authenticates as whatever identity calls
# it, so the applier needs to exist as a Cloud SQL IAM database user here,
# next to the instance, the same way the instance's own built-in `postgres`
# user is instance-level rather than tenant-level.
data "google_service_account" "applier" {
  account_id = "dfo-infra-applier@${var.project_id}.iam.gserviceaccount.com"
}

# The one shared Cloud SQL instance for the environment. Several components
# each take one database inside it rather than standing up an instance of
# their own. The instance is the billed, backed-up server. A database is a
# namespace within it, and Postgres blocks cross-database queries without
# dblink or an FDW, so sharing the server never lets one tenant read
# another's tables. README.md lists the tenants.
resource "google_sql_database_instance" "platform" {
  name             = "${var.namespace}-platform-postgres"
  project          = var.project_id
  region           = var.region
  database_version = "POSTGRES_18"

  # Terraform-side guard against a destroy or a replace. The API-side guard
  # in settings.deletion_protection_enabled below is the one that actually
  # matters, since it survives a config edit that drops this one. That is
  # also why recreating this instance takes two applies, the first to clear
  # both flags and the second to destroy.
  deletion_protection = true

  settings {
    # db-custom-1-3840 is one dedicated vCPU and 3.75 GB, a dedicated-core
    # tier carrying Google's standard SLA. ENTERPRISE keeps this stack on
    # the lighter edition. Production is the same shape stepped up, with
    # availability_type = REGIONAL and a larger tier.
    tier    = var.tier
    edition = "ENTERPRISE"

    # The API-level deletion guard. The top-level deletion_protection
    # comment above says why both exist.
    deletion_protection_enabled = true

    ip_configuration {
      # No public IP and no VPC. This instance is reachable only through the
      # PSC service attachment it publishes (see the psc_service_attachment_uri
      # output), and each consumer creates its own forwarding rule against
      # that attachment in its own stack. A PSC instance binds to no VPC, so
      # building the VPC side here would give the instance a network opinion
      # it shouldn't have.
      ipv4_enabled = false

      ssl_mode = "ENCRYPTED_ONLY"

      psc_config {
        psc_enabled               = true
        allowed_consumer_projects = var.allowed_consumer_projects
      }
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
    }

    database_flags {
      # Each service authenticates as itself with no password to store or
      # rotate. Built-in users (e.g. postgres) stay enabled for migrations.
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    database_flags {
      # 100 is Cloud SQL's own default at 3.75 GB. Cloud SQL derives this
      # value from instance memory when the flag is unset, so pinning it
      # explicitly keeps the connection budget fixed through a future tier
      # change. The budget breaks down as about ten connections for
      # migrations and the built-in users, twenty each for datasets,
      # presentation, apis, and website, and ten for ai, which runs at most
      # two instances each holding a small pool (#155). That sums to one
      # hundred. The website tenant's twenty go to its one service.
      name  = "max_connections"
      value = "100"
    }

    # Query Insights aggregates statistics, text, and plans for every
    # query, plus per-application tags, on every database on this
    # instance. Cloud SQL rejects record_client_address on an instance
    # with PSC connectivity, so it stays at its default of false.
    insights_config {
      query_insights_enabled  = true
      query_plans_per_minute  = 5
      query_string_length     = 1024
      record_application_tags = true
    }

    # Turns on the Cloud SQL Data API's executeSql, the mechanism
    # google_sql_provision_script uses to run SQL against a tenant's database
    # from Terraform without a network path to the PSC-only instance. Every
    # caller still needs cloudsql.instances.executeSql at the IAM layer and a
    # Postgres role to run as — this flag only unlocks the API surface, it
    # grants no one anything by itself.
    data_api_access = "ALLOW_DATA_API"
  }

  depends_on = [google_project_service.apis]
}

# The Postgres-side role the applier's IAM login maps to. Cloud SQL derives
# the username from the service account email with only ".gserviceaccount.com"
# trimmed off — see dcp/dfo.README.md's note on the same convention for the
# Datasets API's runtime user.
#
# `database_roles = ["cloudsqlsuperuser"]` is what lets this role actually run
# a tenant's google_sql_provision_script. A provision script connects as an
# IAM database user, a freshly created IAM user holds no privileges at all,
# and REVOKE/GRANT on a database's own privileges needs that database's owner
# or a superuser — a database created through the Admin API isn't owned by
# the applier. The only other way to grant a role here is a superuser session
# over the wire, and this instance is PSC-only with no path in without first
# building a consumer VPC, so cloudsqlsuperuser is what makes this stack
# self-bootstrapping, for the datasets database and every tenant database
# that lands here after it.
#
# This also lets the applier read every database on the shared instance
# through the Data API, not just the one it happens to be provisioning. That
# thins an already-thin boundary rather than opening a new one: the applier
# already holds roles/cloudsql.admin and roles/secretmanager.admin, so it can
# already drop any of these databases, reset the postgres password, and read
# the migrator password out of Secret Manager.
resource "google_sql_user" "applier" {
  name           = trimsuffix(data.google_service_account.applier.email, ".gserviceaccount.com")
  instance       = google_sql_database_instance.platform.name
  type           = "CLOUD_IAM_SERVICE_ACCOUNT"
  database_roles = ["cloudsqlsuperuser"]

  deletion_policy = "ABANDON"
}

# The `postgres` database belongs to the instance rather than to any tenant,
# so its ACL is owned here. Every Postgres database starts with CONNECT
# granted to PUBLIC, which lets any role on this shared instance open a
# session against `postgres` without anyone granting it. The identity that
# matters is the Datasets API's runtime user, which holds no database roles
# at all and reaches `datasets` only through an explicit grant. Without this
# revoke it would also reach `postgres` through PUBLIC's default grant.
#
# Each tenant database carries its own copy of this revoke in its own stack
# (see dcp's datasets_revoke_public_connect). CREATE DATABASE copies a
# template database's contents rather than its pg_database ACL row, so there
# is no instance-wide setting and no template trick that covers them all.
#
# The GRANT runs first and is what makes this safe to apply. `postgres` is
# the database every provision script in this repo connects to, including any
# script that would undo this one, so the applier's CONNECT has to rest on
# something other than PUBLIC before PUBLIC loses it. Postgres materializes
# the default ACL on whichever statement first touches a NULL `datacl`, which
# here is the GRANT, and every GRANT or REVOKE after that touches only the
# role it names, so the REVOKE below removes PUBLIC's entry and leaves the
# applier's intact. Ordering also covers a partial failure: the Data API
# accepts a semicolon-separated sequence but documents nothing about wrapping
# it in a transaction, and stopping after the GRANT leaves the instance
# exactly as it was.
#
# This script cannot cut off its own session. Postgres checks CONNECT when a
# connection opens, so the REVOKE takes effect on the next one.
resource "google_sql_provision_script" "postgres_revoke_public_connect" {
  project     = var.project_id
  instance    = google_sql_database_instance.platform.name
  database    = "postgres"
  description = "Revokes PUBLIC's default CONNECT on the instance's own postgres database, keeping it for the applier that runs every provision script on this instance."

  script = <<-SQL
    GRANT CONNECT ON DATABASE "postgres" TO "${google_sql_user.applier.name}";
    REVOKE CONNECT ON DATABASE "postgres" FROM PUBLIC;
  SQL
}
