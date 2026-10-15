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
