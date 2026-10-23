# ─────────────────────────────────────────────────────────────────────────────
# TERRAFORM OVERRIDE FILE — reads as a normal .tf file but MERGES into main.tf.
#
# Terraform treats any *_override.tf file specially: the block below does NOT
# define a second module; it REPLACES matching arguments of the base
# `module "stack"` in main.tf and leaves every other argument intact. We use it
# so main.tf can stay byte-identical to what `datacommons admin init --force`
# regenerates (main.tf is CLI-owned and must not be edited).
#
# What it does: rewrites ONLY module.stack's auth_config, swapping the empty
# var-sourced DC API key for the value read from Secret Manager in dfo.tf. The
# other auth_config fields (google_maps_api_key, create_google_maps_key,
# google_maps_allowed_referrers) are preserved from local.auth_config via
# merge().
#
# If you regenerate main.tf, this file and dfo.tf survive untouched and the
# redirection keeps working. See dfo.README.md for the full story.
# ─────────────────────────────────────────────────────────────────────────────
module "stack" {
  auth_config = merge(local.auth_config, {
    google_datacommons_api_key = data.google_secret_manager_secret_version.dc_key.secret_data
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Terraform allows exactly one `required_providers` block per module, and
# main.tf already declares one — so this can't live in a plain dfo_*.tf file
# alongside it without a "Duplicate required providers configuration" error.
# An override file's `terraform` block is exempt from that rule: it replaces
# only the named provider entries in main.tf's block (confirmed against a
# scratch module — the untouched `null` entry keeps main.tf's `>= 3.0`
# constraint while `google` and `random` pick up the bumped floor here) and
# leaves the rest alone, the same merge behavior as the `module "stack"` block
# above. This is the only way to raise a provider floor without editing
# CLI-owned main.tf.
#
# google >= 6.23.0: the release that added the `password_wo` (google_sql_user)
# and `secret_data_wo` (google_secret_manager_secret_version) write-only
# arguments dfo_datasets.tf's migrator credential relies on to keep the
# password out of state.
# random >= 3.7.0: the release that added the `random_password` ephemeral
# resource those write-only arguments source their value from.
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.23.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.7.0"
    }
  }
}
