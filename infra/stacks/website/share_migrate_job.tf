# The Cloud Run Job that moves the website's `share` rows into dfo-apis's
# Presentation store, as dfo-website's `node dist/migrate-shares.cjs`. For
# each owned share it mints or reuses the owner's write token in
# `share_token`, then calls dfo-apis's share import route with the token's
# SHA-256, holding the owner's `user` row while the call runs so an account
# deletion cannot race the import. Guest shares go with no digest. A re-run
# reuses stored tokens and dfo-apis answers an imported share as unchanged,
# so running it twice is safe.
#
# It runs as the website runtime identity, because it writes `share_token`
# with the same DML the service holds, and it calls dfo-apis with an ID token
# minted as that identity, which website_apis_invoker (main.tf) already
# grants. The Job is removed, with the import route and its principal, once
# prod's shares are migrated.

# Bootstrap only, for the reason website_migrate_bootstrap_image records.
# gcr.io/cloudrun/hello has no node binary, so a Job the deploy pipeline has
# not yet moved fails on the command instead of exiting 0.
variable "website_share_migrate_bootstrap_image" {
  description = "Image the share migration Job is created with. The deploy pipeline replaces it per release. This value only has to be an image that cannot run the command, so an unmoved Job fails loudly rather than exiting 0."
  type        = string
  default     = "gcr.io/cloudrun/hello"
}

# The module's secret grants cover the service's own secret_env_vars only, and
# the service does not mount this value, so the Job's identity needs this one.
resource "google_secret_manager_secret_iam_member" "website_share_import_principal_access" {
  secret_id = var.share_import_principal_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.website_runtime_member
}

resource "google_cloud_run_v2_job" "website_share_migrate" {
  name     = "${local.website_name}-share-migrate"
  location = var.region
  project  = var.project_id

  deletion_protection = var.stateless_deletion_protection

  template {
    template {
      service_account = module.website_service.runtime_service_account_email

      # A share the run cannot import is printed and the run exits 1, and an
      # operator fixes the cause and runs it again. A retry would only repeat
      # the same refusals.
      max_retries = 0
      timeout     = "3600s"

      containers {
        image   = var.website_share_migrate_bootstrap_image
        command = ["node"]
        args    = ["dist/migrate-shares.cjs"]

        # The service's connection settings (main.tf), as its runtime user.
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
          value = google_sql_user.website_runtime.name
        }

        env {
          name  = "WEBSITE_DB_INSTANCE_CONNECTION_NAME"
          value = var.platform_postgres_connection_name
        }

        # The apis service the website's proxies call. See var.search_api_base.
        env {
          name  = "SEARCH_API_BASE"
          value = var.search_api_base
        }

        # The apis stack owns and pins the secret. This reads latest, as the
        # service's DFO_PRINCIPAL does, since this stack holds no version
        # resource to pin against.
        env {
          name = "PRESENTATION_SHARE_IMPORT_PRINCIPAL"
          value_source {
            secret_key_ref {
              secret  = var.share_import_principal_secret_id
              version = "latest"
            }
          }
        }
      }

      # The service's private path to Postgres. dfo-apis is reached over its
      # public run.app URL on the default route.
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
    google_project_iam_member.website_cloudsql_client,
    google_project_iam_member.website_cloudsql_login,
    google_secret_manager_secret_iam_member.website_share_import_principal_access,
  ]
}

# The deploy workflow's `gcloud run jobs update --image`, and a manual
# `gcloud run jobs execute`. The actAs grant on the runtime identity comes
# from module.website_service's deployer_members.
resource "google_cloud_run_v2_job_iam_member" "website_share_migrate_deployer_run_developer" {
  project  = google_cloud_run_v2_job.website_share_migrate.project
  location = google_cloud_run_v2_job.website_share_migrate.location
  name     = google_cloud_run_v2_job.website_share_migrate.name
  role     = "roles/run.developer"
  member   = "serviceAccount:${data.google_service_account.website_deployer.email}"
}

output "share_migrate_job_name" {
  description = "Name of the share migration Job. dfo-website's SHARE_MIGRATE_JOB_WEBSITE in this environment's GitHub Environment. Run it with `gcloud run jobs execute <name> --wait`."
  value       = google_cloud_run_v2_job.website_share_migrate.name
}
