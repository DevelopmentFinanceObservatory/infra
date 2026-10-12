terraform {
  # 1.6 for import blocks whose id is an expression (cloudflare_*.tf).
  required_version = ">= 1.6"

  required_providers {
    google = {
      # Every other prod root is locked to 7.x. The cap keeps this one on the
      # same line until they move together.
      source  = "hashicorp/google"
      version = ">= 5.11.0, < 8.0.0"
    }
    cloudflare = {
      # v5 rewrote every resource schema, so the cap keeps a v6 from
      # arriving through a lock refresh.
      source  = "cloudflare/cloudflare"
      version = "~> 5.27"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# The provider reads its API token from the CLOUDFLARE_API_TOKEN environment
# variable. CI sets it from the environment secret of the same name for this
# stack only, and a local run exports it from the keychain.
provider "cloudflare" {}

resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "certificatemanager.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}
