terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.11.0"
    }
  }
}

locals {
  subnet_name           = "${var.network_name}-subnet"
  endpoint_address_name = "${var.network_name}-endpoint"
  forwarding_rule_name  = "${var.network_name}-fwd"
  dns_zone_name         = "${var.network_name}-sql"
}

# A dedicated VPC per consumer, not the project's default network. Its only
# job is to hold the subnet the PSC endpoint attaches to. Nothing else runs
# in it, which is also why there are no firewall rules here. An allow-internal
# set would be guarding traffic that never happens.
resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = var.network_name
  auto_create_subnetworks = false
}

# private_ip_google_access is set here, but it's inert for the only
# wired-up caller: the cloud-run-service module hardcodes PRIVATE_RANGES_ONLY
# egress, which routes only RFC 1918 destinations onto this VPC. Google's API
# ranges (Secret Manager, IAM, ...) are public, so those calls never traverse
# this VPC at all — they take the service's normal public path, same as if
# this were unset. Left set anyway: it's a subnet-level property of a module
# whose callers aren't all fixed, and it would matter to a consumer that
# routed all traffic through here instead. Regional, matching the instance's
# region, since a forwarding rule can only target a service attachment in the
# same region.
resource "google_compute_subnetwork" "this" {
  project                  = var.project_id
  name                     = local.subnet_name
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

# The address the consumer's own services connect to, as if it were the
# instance's private IP. Reserved as its own resource, ahead of the
# forwarding rule, so its value is stable and independent of the rule's
# lifecycle.
resource "google_compute_address" "psc_endpoint" {
  project      = var.project_id
  name         = local.endpoint_address_name
  region       = var.region
  subnetwork   = google_compute_subnetwork.this.id
  address_type = "INTERNAL"
}

# The PSC endpoint itself is a forwarding rule with no backend service,
# targeting the instance's service attachment directly. load_balancing_scheme
# left empty (not "INTERNAL" or "EXTERNAL") is what marks this as a PSC
# consumer endpoint rather than a load balancer frontend. The attachment
# alone authorises nothing. The instance's allowed_consumer_projects has to
# name this project too, or the endpoint sits there unable to connect.
resource "google_compute_forwarding_rule" "psc_endpoint" {
  project               = var.project_id
  name                  = local.forwarding_rule_name
  region                = var.region
  network               = google_compute_network.this.id
  ip_address            = google_compute_address.psc_endpoint.id
  load_balancing_scheme = ""
  target                = var.service_attachment_uri
}

# Hand-built zone, standing in for Cloud SQL's own PSC DNS automation, which
# is Preview-only and unsupported by the Terraform provider
# (hashicorp/terraform-provider-google#27774). Retire this zone and its
# record once that lands. The zone is per-consumer because a private zone
# answers identically on every network it's attached to, and each consumer
# has its own endpoint address. A zone attached to every consumer's VPC
# could publish only one answer for all of them. Zone origin equals the
# record name (an apex record), the narrowest possible answer, resolving
# exactly the instance's name.
resource "google_dns_managed_zone" "psc" {
  project     = var.project_id
  name        = local.dns_zone_name
  dns_name    = "${var.dns_name}."
  description = "Resolves the shared Cloud SQL instance's PSC name to this consumer's endpoint."
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.this.id
    }
  }
}

resource "google_dns_record_set" "psc" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.psc.name
  name         = google_dns_managed_zone.psc.dns_name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.psc_endpoint.address]
}
