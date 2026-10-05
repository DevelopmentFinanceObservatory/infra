# The Cloud Run Job that applies the website's schema migrations, running as
# its own migrator identity (database.tf), not the runtime identity the
# service uses (see main.tf). A Job's target database is only an env var
# its container reads, so the migrator identity is what keeps this Job's
# DDL scoped to the website's own database alone.
#
# It runs as the migrator service account, not the runtime identity.
# Next.js has no run-once startup hook, the service scales out and, in dev,
# to zero, and it is public, so a self-migrating runtime would run DDL on
# every cold start
# and a failed migration would crash-loop a live service. With a separate
# Job, a failed migration fails the deploy and the service stays on its old
# image. The runtime identity holds DML only, so a compromised public
# surface cannot DROP or ALTER, a secondary benefit of the same split.
#
# Migrations run from CI: the owning repo's deploy workflow moves the Job's
# image with `gcloud run jobs update --image`, executes it with `--wait`,
# and updates the service only once the Job exits 0, mirroring
# dfo-apis/.github/workflows/deploy-dev.yml. lifecycle.ignore_changes on the
# image is what keeps that from reading as drift here.

# Bootstrap only. CI moves this per deploy. This value only has to exist and
# fail against the command below, so that a Job executed before CI ever
# points it at a real migration runner fails loudly instead of quietly
# reporting success. gcr.io/cloudrun/hello is guaranteed to exist (the
# website service already uses it as its own bootstrap in main.tf) and
# contains no node binary, so it fails immediately against the command
# below rather than risking "image not found" at Job creation, which a
# guessed tag would.
variable "website_migrate_bootstrap_image" {
  description = "Image the migration Job is created with. The deploy pipeline replaces it per execution. This value only has to be an image that cannot run the command below, so an unmoved Job fails loudly rather than exiting 0."
  type        = string
  default     = "gcr.io/cloudrun/hello"
}

resource "google_cloud_run_v2_job" "website_migrate" {
  name     = "${local.website_name}-migrate"
  location = var.region
  project  = var.project_id

  deletion_protection = var.stateless_deletion_protection

  template {
    template {
      service_account = google_service_account.website_migrator.email

      max_retries = 0
      timeout     = "600s"

      containers {
        image   = var.website_migrate_bootstrap_image
        command = ["node"]
        args    = ["dist/migrate.cjs"]

        env {
          name  = "WEBSITE_DB_HOST"
          value = var.platform_dns_name
        }

        env {
          name  = "WEBSITE_DB_NAME"
          value = google_sql_database.website.name
        }

        env {
          name  = "WEBSITE_DB_INSTANCE_CONNECTION_NAME"
          value = var.platform_postgres_connection_name
        }

        env {
          name  = "WEBSITE_MIGRATOR_DB_USER"
          value = google_sql_user.website_migrator.name
        }

        env {
          name  = "WEBSITE_RUNTIME_DB_USER"
          value = google_sql_user.website_runtime.name
        }
      }

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
    google_project_iam_member.website_migrator_cloudsql_client,
    google_project_iam_member.website_migrator_cloudsql_login,
  ]
}

# Deployer IAM. The website deployer holds project_roles = [] in
# foundation and gets run.developer only on its own service through the
# cloud-run-service module's deployer_members. The Job is created outside
# that module, so it needs the same grant made explicitly here, scoped to
# its own Job only, mirroring datasets_access.tf's actAs grant for the
# datasets migration runner.
resource "google_cloud_run_v2_job_iam_member" "website_migrate_deployer_run_developer" {
  project  = google_cloud_run_v2_job.website_migrate.project
  location = google_cloud_run_v2_job.website_migrate.location
  name     = google_cloud_run_v2_job.website_migrate.name
  role     = "roles/run.developer"
  member   = "serviceAccount:${data.google_service_account.website_deployer.email}"
}

# actAs on the deployer's own migrator, without which a deploy pipeline can
# execute the Job but not attach this service account to it.
resource "google_service_account_iam_member" "website_migrator_deployer_act_as" {
  service_account_id = google_service_account.website_migrator.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${data.google_service_account.website_deployer.email}"
}
