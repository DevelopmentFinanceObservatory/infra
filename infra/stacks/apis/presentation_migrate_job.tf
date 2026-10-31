# The Cloud Run Job that applies the Presentation API's schema migrations. It
# runs the same image as the service, overriding the entrypoint to
# `python -m presentation_store.migrate up`, so the migrations it applies are
# always the ones packaged with the image being deployed. Structurally this
# mirrors datasets_migrate_job.tf exactly; see that file's header for why a
# Job rather than a service-startup step.
#
# Runs as the existing `google_service_account.datasets_migration_runner`
# (datasets_access.tf), not a new dedicated identity. That account's id,
# `dfo-dev-migration-runner`, was already left generic rather than named for
# Datasets specifically, and it holds no Cloud SQL IAM role of its own — only
# Secret Manager reads scoped to the one password secret each migrator needs
# — so reusing it here adds a secret grant rather than a second superuser-
# capable service account.

# The migrator's Postgres username, a plain value in env.auto.tfvars rather
# than a remote-state read, the same rationale variables.tf records for this stack's other
# cross-stack values. The `dcp` stack builds it as
# "${var.namespace}-presentation-migrator" and publishes no output for it, so
# this is a copy of the resulting name.
variable "presentation_migrator_db_user" {
  description = "Postgres username of the built-in migrator role declared as google_sql_user.presentation_migrator in the `dcp` stack."
  type        = string
}

# Bootstrap only. An operator points the Job at the image being deployed with
# `gcloud run jobs update --image` before each execution, and
# lifecycle.ignore_changes below keeps that from reading as drift. Migrations
# run by hand rather than from CI because they are forward-only with no
# rollback, which is the same reason max_retries is 0 below.
#
# The tag has to carry `presentation_store`, which entered the dfo-apis image
# later than `dataset_store` did. An image predating that module exits on
# `No module named presentation_store`, which is what an operator executing
# the freshly created Job sees before the pipeline has moved it.
# local.live_apis_image (main.tf) always satisfies this: the deploy pipeline
# builds one image per commit for the whole app, and presentation_store has
# been part of that image since before this stack's own datasets_worker
# resources existed.
variable "presentation_migrate_bootstrap_image" {
  description = "Overrides the image the migration Job is created with. The deploy pipeline replaces it per execution; null (the default) bootstraps from local.live_apis_image, the tag the apis service is currently running — always a real dfo-apis image that carries presentation_store."
  type        = string
  default     = null
}

# Scoped to the one secret the runner needs, not a project-level grant —
# mirrors datasets_migrator_secret_reader in datasets_access.tf. The runner
# reaches the instance over plain TCP at its PSC endpoint address and
# authenticates as the presentation migrator user with this password, so it
# takes no Cloud SQL IAM role or google_sql_user here.
resource "google_secret_manager_secret_iam_member" "presentation_migrator_secret_reader" {
  secret_id = var.presentation_migrator_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.datasets_migration_runner.email}"
}

resource "google_cloud_run_v2_job" "presentation_migrate" {
  name     = "${var.namespace}-presentation-migrate"
  location = var.region
  project  = var.project_id

  deletion_protection = var.stateless_deletion_protection

  template {
    template {
      service_account = google_service_account.datasets_migration_runner.email

      # Forward-only migrations with no rollback command: a retry of a failed
      # run would re-enter a database whose state the failure left unknown.
      # An operator reads the logs and decides instead.
      max_retries = 0
      timeout     = "600s"

      containers {
        image   = coalesce(var.presentation_migrate_bootstrap_image, local.live_apis_image)
        command = ["python"]
        args    = ["-m", "presentation_store.migrate", "up"]

        # Plain TCP straight to the PSC endpoint address, deliberately without
        # PRESENTATION_STORE_INSTANCE_CONNECTION_NAME. Setting it would route
        # the connection through the Cloud SQL Python Connector instead, which
        # buys nothing here. The migrator is a BUILT_IN password user, so
        # there's no IAM token for the connector to mint.
        env {
          name  = "PRESENTATION_STORE_HOST"
          value = module.psc_network.endpoint_ip_address
        }

        env {
          name  = "PRESENTATION_STORE_PORT"
          value = "5432"
        }

        env {
          name  = "PRESENTATION_STORE_DATABASE"
          value = var.presentation_database_name
        }

        env {
          name  = "PRESENTATION_STORE_MIGRATOR_DB_USER"
          value = var.presentation_migrator_db_user
        }

        # The runner substitutes this into the migrations' GRANT statements.
        # It names the role the grants target — the shared apis runtime user
        # (google_sql_user.datasets_runtime), not the identity this Job
        # authenticates as.
        env {
          name  = "PRESENTATION_STORE_RUNTIME_DB_USER"
          value = google_sql_user.datasets_runtime.name
        }

        env {
          name = "PRESENTATION_STORE_MIGRATOR_DB_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = var.presentation_migrator_secret_id
              version = "latest"
            }
          }
        }
      }

      # Direct VPC egress onto this stack's PSC subnet, the same path the
      # service and the datasets migration Job use. PRIVATE_RANGES_ONLY keeps
      # everything else on the default internet route: the Job needs no
      # outbound public access.
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

  depends_on = [google_secret_manager_secret_iam_member.presentation_migrator_secret_reader]
}

# The deployer updates this Job's image and executes it with `--wait`. Cloud
# Run Developer supplies that Job-scoped access. The deployer's actAs grant on
# the runner is in datasets_access.tf.
resource "google_cloud_run_v2_job_iam_member" "presentation_migrate_deployer_run_developer" {
  project  = google_cloud_run_v2_job.presentation_migrate.project
  location = google_cloud_run_v2_job.presentation_migrate.location
  name     = google_cloud_run_v2_job.presentation_migrate.name
  role     = "roles/run.developer"
  member   = "serviceAccount:${data.google_service_account.apis_deployer.email}"
}

output "presentation_migrate_job_name" {
  description = "Name of the migration Job. Run it with `gcloud run jobs execute`, after `gcloud run jobs update --image` points it at the image being deployed."
  value       = google_cloud_run_v2_job.presentation_migrate.name
}
