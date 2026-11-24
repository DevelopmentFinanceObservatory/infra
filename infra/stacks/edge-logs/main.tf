terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      # Every other prod root is locked to 7.x. The cap keeps this one on the
      # same line until they move together.
      source  = "hashicorp/google"
      version = ">= 5.11.0, < 8.0.0"
    }
    cloudflare = {
      # The edge stack's pin. v5 rewrote every resource schema, so the cap
      # keeps a v6 from arriving through a lock refresh.
      source  = "cloudflare/cloudflare"
      version = "~> 5.27"
    }
  }
}

# Reads the ownership challenge file from the telemetry stack's bucket.
provider "google" {
  project = var.project_id
}

# The provider reads its API token from the CLOUDFLARE_API_TOKEN environment
# variable. CI sets it from the production environment's secret of that name
# in apply-stack.yml, and a local run exports it from the keychain. The token
# needs Logs Write on the zone.
provider "cloudflare" {}
