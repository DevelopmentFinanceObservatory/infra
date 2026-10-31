# DFO-specific infrastructure — additions on our side, kept separate from
# main.tf so regenerating the upstream Data Commons stack scaffolding never
# clobbers them.

# The Data Commons API key comes from this hand-seeded secret, not from
# dfo.auto.tfvars and not from var.auth_google_datacommons_api_key (which stays
# at its "" default). dfo_override.tf injects it into module.stack's auth_config.
# This is the input secret, distinct from the module-managed dfo-dev-dc-api-key
# the stack creates downstream of it. See dfo.README.md, "The DC key
# redirection", for why the wiring works this way.
data "google_secret_manager_secret_version" "dc_key" {
  secret = "projects/${var.project_id}/secrets/dc-api-key"
}

# Stop plan and apply loudly when the sourced key is empty, rather than letting
# the module blank the live DC key. A precondition hard-fails; a `check` would
# only warn.
#
# The same guard fails plan when region or namespace is left at its upstream
# default. variables.tf is CLI-owned and keeps those defaults ("us-central1"
# and ""), so an environment's dfo.auto.tfvars that omits either would
# otherwise deploy to the wrong region or under unprefixed names.
resource "null_resource" "dc_key_guard" {
  lifecycle {
    precondition {
      condition     = data.google_secret_manager_secret_version.dc_key.secret_data != ""
      error_message = "Data Commons API key is empty. It is sourced from the dc-api-key Secret Manager secret and wired into module.stack.auth_config by dfo_override.tf. Add a non-empty version to that secret (owner: gcloud secrets versions add) before planning dcp."
    }
    precondition {
      condition     = var.region != "us-central1"
      error_message = "region is the upstream default \"us-central1\". Set it in this environment's dfo.auto.tfvars."
    }
    precondition {
      condition     = var.namespace != ""
      error_message = "namespace is empty, the upstream default. Set it in this environment's dfo.auto.tfvars."
    }
  }
}

# Declared here, not in variables.tf, which keeps the upstream CLI's variables.
# Prod gives each Gemini caller its own key from its own AI Studio project, so
# the billing export attributes spend by project. Dev shares one key.
variable "search_api_gemini_api_key_secret_id" {
  description = "Secret Manager id of the Gemini API key set on the Data Commons service as GEMINI_API_KEY for the DFO prototype app, such as dfo-prod-dcp-gemini-api-key. Created outside Terraform, and it must hold a version, or the revision the script creates cannot start."
  type        = string
}

# Fails the plan when the secret does not exist, before the grant and the
# script point at it.
data "google_secret_manager_secret" "search_api_gemini" {
  secret_id = var.search_api_gemini_api_key_secret_id
}

# The serving SA reads the Gemini key secret through this per-secret grant.
# The stack module grants it the DC and Maps key secrets the same way and no
# project-wide secretmanager.secretAccessor.
resource "google_secret_manager_secret_iam_member" "serving_sa_gemini_key" {
  project   = var.project_id
  secret_id = data.google_secret_manager_secret.search_api_gemini.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${module.stack.datacommons_service_service_account_email}"
}

# Wire GEMINI_API_KEY onto the datacommons service for the DFO prototype app
# (the Next.js server custom_dc/dfo/start.sh launches behind /prototype). Two of
# its routes read the key:
#
# - /prototype/api/similarity embeds text through the Gemini API. Without the
#   key it falls back to deterministic pseudo-embeddings, so it still answers
#   but its scores are not real.
# - /prototype/api/skill-compare runs a Gemini agent. Without the key both arms
#   return "No Gemini API key configured" and no answer.
#
# /api/search/* does not depend on the key: the prototype app proxies it to
# dfo-apis. The website and mixer do not read it either, since DataGemma only
# loads when ENABLE_DATAGEMMA=true, which this stack does not set.
#
# The key lives in Secret Manager as var.search_api_gemini_api_key_secret_id,
# and the serving SA reads it through the per-secret grant above.
#
# The pinned stack module takes no input for adding secret env vars, so the key
# goes on after the module deploys the service. The script header explains why it
# calls the Cloud Run Admin API instead of gcloud.
#
# The module stamps FORCE_RESTART=timestamp() and publishes a fresh revision
# without GEMINI_API_KEY on every apply, so this has to re-run every apply, hence
# the timestamp() trigger. Between the module's revision and the script's, the
# two routes above run without the key. If the script fails, the apply fails and
# the keyless revision keeps serving. That includes a revision Cloud Run cannot
# start because the serving SA cannot read the secret: the script reports the
# failed rollout and traffic stays on the module's revision. Rerun the script by
# hand with the same arguments to recover.
resource "null_resource" "search_api_gemini_key" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<-EOT
      "${path.root}/../../../scripts/set-search-api-gemini-key.sh" \
        ${var.project_id} \
        ${var.region} \
        ${module.stack.datacommons_service_name} \
        ${data.google_secret_manager_secret.search_api_gemini.secret_id}
    EOT
  }

  depends_on = [
    module.stack,
    google_secret_manager_secret_iam_member.serving_sa_gemini_key,
  ]
}

# dcp-tools reads the ingestion workflow's definition (workflows.workflows.get)
# before it starts an execution, and it does so as the workflow service account
# when the caller impersonates it. The stack module grants that account only
# roles/workflows.invoker, which lacks the permission.
resource "google_project_iam_member" "ingestion_workflow_sa_viewer" {
  count = var.enable_ingestion ? 1 : 0

  project = var.project_id
  role    = "roles/workflows.viewer"
  member  = "serviceAccount:${module.stack.ingestion_workflow_service_account_email}"
}

# DCP 1.1.6 runs preprocessing on Cloud Batch and drops the Cloud Run
# preprocessing job. Prod state holds that job with deletion_protection = true,
# a Terraform-side flag that blocks the destroy, and the module no longer
# declares the job, so no apply can clear the flag first. Terraform forgets the
# job here, and infra/dfo-prod/dcp/dfo.README.md, "Retired preprocessing job",
# gives the gcloud command that deletes it.
removed {
  from = module.stack.module.ingestion_preprocessing_job.google_cloud_run_v2_job.dc_data_job

  lifecycle {
    destroy = false
  }
}
