locals {
  # GCP service account ids are capped at 30 chars; truncate defensively so a
  # longer service_name can't produce an invalid account_id.
  runtime_account_id = substr("${var.service_name}-run", 0, 30)

  # Compute the grant set from what's actually consumed so it can't drift:
  # every secret referenced by secret_env_vars gets exactly one accessor
  # grant, no more.
  secret_ids = toset([for e in var.secret_env_vars : e.secret_id])
}

# Dedicated least-privilege runtime identity for the Cloud Run service,
# distinct from the CI deployer (which never runs as the service).
resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = local.runtime_account_id
  display_name = "${var.service_name} Cloud Run runtime identity"
}

# Per-secret accessor grants only on the secrets this service actually
# references — never a project-level binding.
resource "google_secret_manager_secret_iam_member" "runtime_secret_access" {
  for_each  = local.secret_ids
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.runtime.member
}

# Let the image-deployer (the owning repo's CI) attach the runtime SA to each
# new revision. `gcloud run services update --image` creates a revision that
# runs as this SA, and attaching an SA to a revision requires actAs on it — so
# an image-only deploy fails without this grant, not only an SA change.
resource "google_service_account_iam_member" "deployer_act_as" {
  for_each           = toset(var.deployer_members)
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value
}

resource "google_cloud_run_v2_service" "this" {
  name     = var.service_name
  location = var.region
  project  = var.project_id

  deletion_protection = var.deletion_protection

  # Combined instance cap across every revision receiving traffic, distinct
  # from the per-revision template.scaling below. See the README's
  # "Service-level instance cap" section.
  dynamic "scaling" {
    for_each = var.service_max_instances != null ? [var.service_max_instances] : []
    content {
      max_instance_count = scaling.value
    }
  }

  template {
    service_account  = google_service_account.runtime.email
    session_affinity = var.session_affinity

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    # Threads var.readiness_dependencies' ids into a non-functional
    # annotation, since a module-level depends_on would force a cycle
    # through runtime_service_account_email. See the README's "Ordering a
    # revision on out-of-module resources" section.
    annotations = length(var.readiness_dependencies) > 0 ? {
      "readiness-dependencies" = join(",", var.readiness_dependencies)
    } : {}

    # The API requires a duration string like "300s". var.timeout_seconds
    # stays a plain number so its validation block can bound it.
    timeout = "${var.timeout_seconds}s"

    containers {
      image = var.bootstrap_image

      ports {
        container_port = var.container_port
      }

      dynamic "env" {
        for_each = var.env_vars
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secret_env_vars
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value.secret_id
              version = env.value.version
            }
          }
        }
      }

      # cpu_idle and startup_cpu_boost are set explicitly here. With limits
      # present but cpu_idle omitted, the provider sends false, which keeps
      # CPU allocated continuously.
      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle          = var.cpu_idle
        startup_cpu_boost = var.startup_cpu_boost
      }

      # Deliberately no startup/liveness HTTP probe against /healthz here:
      # the bootstrap placeholder image does not serve that path, so a probe
      # would fail the very first apply. Add one as a follow-up once the
      # owning repo's real image has landed.
    }

    # Direct VPC egress onto a consumer's own PSC subnet, absent for ai
    # (var.vpc_access stays null). egress is hardcoded to PRIVATE_RANGES_ONLY
    # rather than exposed as a caller choice: a consumer-psc-network subnet
    # (see that module's README) deliberately has no NAT gateway, so
    # ALL_TRAFFIC would take every outbound call — including ones to public
    # APIs like Gemini and the Data Commons graph — through a network with no
    # route out.
    dynamic "vpc_access" {
      for_each = var.vpc_access != null ? [var.vpc_access] : []
      content {
        egress = "PRIVATE_RANGES_ONLY"

        network_interfaces {
          network    = vpc_access.value.network
          subnetwork = vpc_access.value.subnetwork
        }
      }
    }
  }

  lifecycle {
    # Load-bearing: this is what lets the owning repo's CI own the image via
    # image-only `gcloud run services update` without Terraform reverting it
    # to var.bootstrap_image on the next apply.
    #
    # client/client_version record which tool last mutated the service, and
    # `gcloud run services update` stamps itself into them. They are owned by
    # whoever deployed last, the same way the image is. Without them here,
    # every plan after a deploy proposes nulling them and every deploy sets
    # them again, so the stack never plans clean and the noise trains readers
    # to skim the one output that has to stay meaningful.
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [google_secret_manager_secret_iam_member.runtime_secret_access]
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  count    = var.allow_unauthenticated ? 1 : 0
  project  = google_cloud_run_v2_service.this.project
  location = google_cloud_run_v2_service.this.location
  name     = google_cloud_run_v2_service.this.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# roles/run.developer scoped to this service alone, rather than a
# project-wide grant. run.services.get and run.services.update — everything
# `gcloud run services update --image --region --project` needs — are both
# checked against the service resource, so this is sufficient for an
# image-only deploy.
resource "google_cloud_run_v2_service_iam_member" "deployer_run_developer" {
  for_each = toset(var.deployer_members)
  project  = google_cloud_run_v2_service.this.project
  location = google_cloud_run_v2_service.this.location
  name     = google_cloud_run_v2_service.this.name
  role     = "roles/run.developer"
  member   = each.value
}
