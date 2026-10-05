# The Cloud Run Job that applies the Datasets API's schema migrations. It runs
# the same image as the service, overriding the entrypoint to
# `python -m dataset_store.migrate up`, so the migrations it applies are always
# the ones packaged with the image being deployed.
#
# A Job rather than a step in the service: migrations run to completion and
# exit, and they must land before the image that expects the new schema
# serves traffic. The owning repo's deploy workflow refuses a push-triggered
# deploy while HEAD carries migration files the deployed image predates.

# The migrator's Postgres username, a plain value in env.auto.tfvars rather
# than a remote-state read, the same rationale variables.tf records for this stack's other
# cross-stack values. The `dcp` stack builds it as
# "${var.namespace}-datasets-migrator" and publishes no output for it, so this
# is a copy of the resulting name.
variable "datasets_migrator_db_user" {
  description = "Postgres username of the built-in migrator role declared as google_sql_user.datasets_migrator in the `dcp` stack."
  type        = string
}

# Bootstrap only. The deploy pipeline moves this with `gcloud run jobs update
# --image` before each execution, and lifecycle.ignore_changes below keeps
# that from reading as drift.
#
# A real application image rather than a placeholder like the service module's
# `gcr.io/cloudrun/hello`: a placeholder exits 0 without touching the
# database, so an execution against a Job whose image was never updated would
# report success having applied nothing.
variable "datasets_migrate_bootstrap_image" {
  description = "Overrides the image the migration Job is created with. The deploy pipeline replaces it per execution; null (the default) bootstraps from local.live_apis_image, the tag the apis service is currently running — always a real dfo-apis image that carries the migration runner."
  type        = string
  default     = null
}

resource "google_cloud_run_v2_job" "datasets_migrate" {
  name     = "${var.namespace}-datasets-migrate"
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
        image   = coalesce(var.datasets_migrate_bootstrap_image, local.live_apis_image)
        command = ["python"]
        args    = ["-m", "dataset_store.migrate", "up"]

        # Plain TCP straight to the PSC endpoint address, deliberately without
        # DATASET_STORE_INSTANCE_CONNECTION_NAME. Setting it would route the
        # connection through the Cloud SQL Python Connector instead, which
        # buys nothing here. The migrator is a BUILT_IN password user, so
        # there's no IAM token for the connector to mint.
        env {
          name  = "DATASET_STORE_HOST"
          value = module.psc_network.endpoint_ip_address
        }

        env {
          name  = "DATASET_STORE_PORT"
          value = "5432"
        }

        env {
          name  = "DATASET_STORE_DATABASE"
          value = var.datasets_database_name
        }

        env {
          name  = "DATASET_STORE_MIGRATOR_DB_USER"
          value = var.datasets_migrator_db_user
        }

        # The runner substitutes this into 0001's GRANT statements. It names
        # the role the grants target, and is not the identity this Job
        # authenticates as.
        env {
          name  = "DATASET_STORE_RUNTIME_DB_USER"
          value = google_sql_user.datasets_runtime.name
        }

        # The runner substitutes this into 0012's `GRANT ... TO
        # "{{WORKER_DB_USER}}"` statement, making the worker's IAM database
        # user a member of the runtime role.
        env {
          name  = "DATASET_STORE_WORKER_DB_USER"
          value = google_sql_user.datasets_worker_runtime.name
        }

        env {
          name = "DATASET_STORE_MIGRATOR_DB_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = var.datasets_migrator_secret_id
              version = "latest"
            }
          }
        }
      }

      # Direct VPC egress onto this stack's PSC subnet, the same path the
      # service uses. PRIVATE_RANGES_ONLY keeps everything else on the
      # default internet route: the Job needs no outbound public access.
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
    google_secret_manager_secret_iam_member.datasets_migrator_secret_reader,
    google_sql_user.datasets_worker_runtime,
  ]
}

# The deployer updates this Job's image and executes it with `--wait`. Cloud
# Run Developer supplies that Job-scoped access. The deployer's actAs grant on
# the runner is in datasets_access.tf.
resource "google_cloud_run_v2_job_iam_member" "datasets_migrate_deployer_run_developer" {
  project  = google_cloud_run_v2_job.datasets_migrate.project
  location = google_cloud_run_v2_job.datasets_migrate.location
  name     = google_cloud_run_v2_job.datasets_migrate.name
  role     = "roles/run.developer"
  member   = "serviceAccount:${data.google_service_account.apis_deployer.email}"
}

output "datasets_migrate_job_name" {
  description = "Name of the migration Job. Run it with `gcloud run jobs execute`, after `gcloud run jobs update --image` points it at the image being deployed."
  value       = google_cloud_run_v2_job.datasets_migrate.name
}
