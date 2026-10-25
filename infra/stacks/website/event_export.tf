# The website event export: a Cloud Run Job running dfo-website's
# `node dist/export-events.cjs` every hour, copying the `event` table into
# the BigQuery dataset `website_export`. Each run replaces one partition per
# day, from the latest loaded day minus one through today, and the job
# creates its own `event` table there. Visitor and user ids leave Postgres
# only as HMAC-SHA256 under EXPORT_ID_HMAC_KEY.
#
# The exporter's identity, its Postgres user and the `website_export_reader`
# role exist in every tier, because dfo-website's migration that runs
# `GRANT SELECT ON "event" TO website_export_reader` runs in every tier and
# fails if the role is missing. The dataset, key, Job and trigger exist only
# where var.event_export_enabled is true, which is dfo-prod.

variable "event_export_enabled" {
  description = "Creates the website_export dataset, the ID hashing key, the export Job and its hourly trigger. On in dfo-prod, off in dfo-dev. The exporter identity and its database role exist either way."
  type        = bool
  default     = false
}

locals {
  event_export_count = var.event_export_enabled ? 1 : 0
  # The role dfo-website's migration grants SELECT on "event" to. One name in
  # every tier, so the migration needs no templating. Roles are
  # instance-wide in Postgres; each instance hosts one website database.
  website_export_reader_role = "website_export_reader"
}

# ─────────────────────────────────────────────────────────────────────────────
# Exporter identity and its database access (every tier)
# ─────────────────────────────────────────────────────────────────────────────

# The tier is abbreviated for the 30-character account_id cap, as for the
# migrator: dfo-dev-website-stg-export (26), dfo-prod-website-export (23).
resource "google_service_account" "website_export" {
  account_id   = "${var.namespace}-website${local.tier_suffix_short}-export"
  display_name = "Website event export Job (${var.tier})"
}

# Named from the account, as google_sql_user.website_runtime is, so the
# Postgres role depends on the account existing.
resource "google_sql_user" "website_export" {
  name     = trimsuffix(google_service_account.website_export.email, ".gserviceaccount.com")
  instance = var.platform_postgres_instance_name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"

  deletion_policy = "ABANDON"
}

# The same login pair the runtime user and the migrator hold (database.tf):
# cloudsql.client for the connector's certificate, the login-only custom role
# for the IAM login, and no Data API execute.
resource "google_project_iam_member" "website_export_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.website_export.member
}

resource "google_project_iam_member" "website_export_cloudsql_login" {
  project = var.project_id
  role    = google_project_iam_custom_role.cloudsql_login_only.id
  member  = google_service_account.website_export.member
}

# Creates the read-only role and makes the exporter a member. Every privilege
# sits on the role: CONNECT here, USAGE on the schema below, and SELECT on
# "event" from dfo-website's migration. Postgres has no CREATE ROLE IF NOT
# EXISTS, so the DO block keeps a re-run from failing. The script connects
# to `postgres`, as website_db_acl does, since roles and pg_database are
# shared catalogs. The applier creates the role, and Postgres 16 and later
# give a CREATEROLE creator ADMIN OPTION on it, which the GRANT to the
# exporter needs.
resource "google_sql_provision_script" "website_export_reader" {
  project     = var.project_id
  instance    = var.platform_postgres_instance_name
  database    = "postgres"
  description = "Creates the NOLOGIN role ${local.website_export_reader_role} if absent, grants it CONNECT on the ${google_sql_database.website.name} database, and grants it to the ${var.tier} exporter user."

  script = <<-SQL
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${local.website_export_reader_role}') THEN
        CREATE ROLE "${local.website_export_reader_role}" NOLOGIN;
      END IF;
    END
    $$;
    GRANT CONNECT ON DATABASE "${google_sql_database.website.name}" TO "${local.website_export_reader_role}";
    GRANT "${local.website_export_reader_role}" TO "${google_sql_user.website_export.name}";
  SQL

  # The REVOKE of PUBLIC's CONNECT runs first, so the role's CONNECT is the
  # exporter's only way in.
  depends_on = [google_sql_provision_script.website_db_acl]
}

# USAGE on the public schema is a per-database privilege, so this script
# connects to the website database itself, as website_db_schema_grant does.
# The migrator cannot grant it (database.tf records why).
resource "google_sql_provision_script" "website_export_reader_schema" {
  project     = var.project_id
  instance    = var.platform_postgres_instance_name
  database    = google_sql_database.website.name
  description = "Grants ${local.website_export_reader_role} USAGE on the public schema of the ${google_sql_database.website.name} database."

  script = <<-SQL
    GRANT USAGE ON SCHEMA public TO "${local.website_export_reader_role}";
  SQL

  depends_on = [google_sql_provision_script.website_export_reader]
}

# ─────────────────────────────────────────────────────────────────────────────
# APIs and dataset (dfo-prod)
# ─────────────────────────────────────────────────────────────────────────────

# Both APIs are already on in prod (dcp enables BigQuery, apis Cloud
# Scheduler). Declaring them keeps this stack's applies independent of those
# stacks. disable_on_destroy = false leaves them on for the other owners.
resource "google_project_service" "event_export" {
  for_each = var.event_export_enabled ? toset([
    "bigquery.googleapis.com",
    "cloudscheduler.googleapis.com",
  ]) : toset([])

  service            = each.key
  disable_on_destroy = false
}

# EU multi-region, the location of every dataset the reporting views read.
# The location cannot change after creation.
resource "google_bigquery_dataset" "website_export" {
  count = local.event_export_count

  project     = var.project_id
  dataset_id  = "website_export"
  location    = "EU"
  description = "Website product events from the ${google_sql_database.website.name} database's event table, with visitor and user ids as keyed hashes and no free text. Loaded hourly by the ${local.website_name}-export Job."

  # No access blocks: every grant on this dataset is a
  # google_bigquery_dataset_access resource, here and in the telemetry stack's
  # authorised views. Access blocks would make the dataset's ACL authoritative
  # and drop those entries on the next apply.

  depends_on = [google_project_service.event_export]
}

# Running a load job is authorised at the project level only. This grant reads
# and writes no table by itself.
resource "google_project_iam_member" "website_export_bigquery_job_user" {
  count = local.event_export_count

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.website_export.member
}

# WRITER is the dataset-level form of roles/bigquery.dataEditor: create the
# table, replace partitions, and read the latest loaded day. The API stores a
# predefined role here as WRITER, so naming the predefined role would plan a
# change on every apply.
resource "google_bigquery_dataset_access" "website_export_writer" {
  count = local.event_export_count

  project       = var.project_id
  dataset_id    = google_bigquery_dataset.website_export[0].dataset_id
  role          = "WRITER"
  user_by_email = google_service_account.website_export.email
}

# ─────────────────────────────────────────────────────────────────────────────
# ID hashing key (dfo-prod)
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # Single counter for the write-only pair below. The ephemeral key regenerates
  # every plan but only reaches the secret version when this number changes.
  # Bump it to rotate. Rotating changes every hashed id, so rows loaded before
  # and after no longer join (see README.md).
  website_export_hmac_key_version = 1
}

# Alphanumeric only, following the caller HMAC key pattern.
ephemeral "random_password" "website_export_hmac_key" {
  count = local.event_export_count

  length  = 48
  special = false
}

resource "google_secret_manager_secret" "website_export_hmac_key" {
  count = local.event_export_count

  secret_id = "${local.website_name}-export-hmac-key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "website_export_hmac_key" {
  count = local.event_export_count

  secret                 = google_secret_manager_secret.website_export_hmac_key[0].id
  secret_data_wo         = ephemeral.random_password.website_export_hmac_key[0].result
  secret_data_wo_version = local.website_export_hmac_key_version

  lifecycle {
    # A counter bump replaces this resource, and the replacement must exist
    # before the old version is destroyed so the Job's pinned reference never
    # points at nothing.
    create_before_destroy = true
  }
}

resource "google_secret_manager_secret_iam_member" "website_export_hmac_key_access" {
  count = local.event_export_count

  secret_id = google_secret_manager_secret.website_export_hmac_key[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.website_export.member
}

# ─────────────────────────────────────────────────────────────────────────────
# Job (dfo-prod)
# ─────────────────────────────────────────────────────────────────────────────

# Bootstrap only, for the reason website_migrate_bootstrap_image records.
# gcr.io/cloudrun/hello has no node binary, so a Job the deploy pipeline has
# not yet moved fails on the command instead of exiting 0.
variable "website_export_bootstrap_image" {
  description = "Image the event export Job is created with. The deploy pipeline replaces it per release. This value only has to be an image that cannot run the command, so an unmoved Job fails loudly rather than exiting 0."
  type        = string
  default     = "gcr.io/cloudrun/hello"
}

resource "google_cloud_run_v2_job" "website_export" {
  count = local.event_export_count

  name     = "${local.website_name}-export"
  location = var.region
  project  = var.project_id

  deletion_protection = var.stateless_deletion_protection

  template {
    template {
      service_account = google_service_account.website_export.email

      # A run replaces whole days, so a failed run is healed by the next
      # hourly run reading the same window. 30 minutes also keeps one
      # execution from overlapping the next trigger.
      max_retries = 0
      timeout     = "1800s"

      containers {
        image   = var.website_export_bootstrap_image
        command = ["node"]
        args    = ["dist/export-events.cjs"]

        # The service's connection settings (main.tf), with the exporter's
        # own IAM database user.
        env {
          name  = "WEBSITE_DB_HOST"
          value = var.platform_dns_name
        }

        env {
          name  = "WEBSITE_DB_NAME"
          value = google_sql_database.website.name
        }

        env {
          name  = "WEBSITE_DB_USER"
          value = google_sql_user.website_export.name
        }

        env {
          name  = "WEBSITE_DB_INSTANCE_CONNECTION_NAME"
          value = var.platform_postgres_connection_name
        }

        env {
          name  = "EXPORT_BQ_PROJECT"
          value = var.project_id
        }

        env {
          name  = "EXPORT_BQ_DATASET"
          value = google_bigquery_dataset.website_export[0].dataset_id
        }

        # Pinned, so a rotation reaches the Job in the same apply that
        # creates the new version.
        env {
          name = "EXPORT_ID_HMAC_KEY"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.website_export_hmac_key[0].secret_id
              version = google_secret_manager_secret_version.website_export_hmac_key[0].version
            }
          }
        }
      }

      # The service's private path to Postgres. BigQuery is reached over
      # the public API surface on the default route.
      vpc_access {
        network_interfaces {
          network    = module.psc_network.network_id
          subnetwork = module.psc_network.subnetwork_id
        }
        egress = "PRIVATE_RANGES_ONLY"
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [
    google_project_iam_member.website_export_cloudsql_client,
    google_project_iam_member.website_export_cloudsql_login,
    google_sql_provision_script.website_export_reader_schema,
    google_project_iam_member.website_export_bigquery_job_user,
    google_bigquery_dataset_access.website_export_writer,
    google_secret_manager_secret_iam_member.website_export_hmac_key_access,
  ]
}

# The deploy workflow's `gcloud run jobs update --image`, and a manual
# `gcloud run jobs execute`.
resource "google_cloud_run_v2_job_iam_member" "website_export_deployer_run_developer" {
  count = local.event_export_count

  project  = google_cloud_run_v2_job.website_export[0].project
  location = google_cloud_run_v2_job.website_export[0].location
  name     = google_cloud_run_v2_job.website_export[0].name
  role     = "roles/run.developer"
  member   = "serviceAccount:${data.google_service_account.website_deployer.email}"
}

# actAs so the deployer can update the Job, whose new revision runs as the
# exporter.
resource "google_service_account_iam_member" "website_export_deployer_act_as" {
  count = local.event_export_count

  service_account_id = google_service_account.website_export.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${data.google_service_account.website_deployer.email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Scheduler (dfo-prod)
# ─────────────────────────────────────────────────────────────────────────────

# A dedicated identity purely to authenticate the Scheduler->Cloud Run Admin
# API call. It runs as nothing and holds no other grant.
resource "google_service_account" "website_export_scheduler" {
  count = local.event_export_count

  account_id   = "${var.namespace}-website${local.tier_suffix_short}-export-sch"
  display_name = "Website event export Job Cloud Scheduler trigger (${var.tier})"
}

# run.jobs.run on this one Job. The trigger passes no overrides, so
# roles/run.invoker is enough.
resource "google_cloud_run_v2_job_iam_member" "website_export_scheduler_invoker" {
  count = local.event_export_count

  project  = google_cloud_run_v2_job.website_export[0].project
  location = google_cloud_run_v2_job.website_export[0].location
  name     = google_cloud_run_v2_job.website_export[0].name
  role     = "roles/run.invoker"
  member   = google_service_account.website_export_scheduler[0].member
}

# The Cloud Run Admin API's run call, the same oauth_token target the apis
# stack's graph_release.tf uses.
resource "google_cloud_scheduler_job" "website_export" {
  count = local.event_export_count

  name      = "${local.website_name}-export-tick"
  project   = var.project_id
  region    = var.region
  schedule  = "0 * * * *"
  time_zone = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.website_export[0].name}:run"

    oauth_token {
      service_account_email = google_service_account.website_export_scheduler[0].email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.event_export,
    google_cloud_run_v2_job_iam_member.website_export_scheduler_invoker,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────────────────────────────────────

output "export_job_name" {
  description = "Name of the event export Job, null where the export is off. dfo-website's EXPORT_JOB_WEBSITE in this environment's GitHub Environment."
  value       = one(google_cloud_run_v2_job.website_export[*].name)
}

output "export_service_account" {
  description = "Email of the event exporter's service account, in every tier."
  value       = google_service_account.website_export.email
}

output "export_database_user" {
  description = "Postgres IAM user the exporter logs in as, a member of website_export_reader, in every tier."
  value       = google_sql_user.website_export.name
}
