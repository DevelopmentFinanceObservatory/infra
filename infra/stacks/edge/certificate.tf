# The certificate the load balancer presents to Cloudflare. Cloudflare's SSL
# mode is Full (strict), so it validates this certificate on every request to
# the origin.
#
# A per-project DNS authorization puts its CNAME at
# _acme-challenge_<suffix>.<domain>. The fixed-record type would use
# _acme-challenge.<domain>, where Cloudflare's Universal SSL serves its own
# ACME TXT records, and Google requires the CNAME to be the only record at
# its name.
resource "google_certificate_manager_dns_authorization" "apex" {
  name   = "${var.namespace}-edge-apex"
  domain = var.domain
  type   = "PER_PROJECT_RECORD"

  depends_on = [google_project_service.apis]
}

# One authorization on the apex covers the wildcard too.
resource "google_certificate_manager_certificate" "edge" {
  name = "${var.namespace}-edge"

  managed {
    domains            = [var.domain, "*.${var.domain}"]
    dns_authorizations = [google_certificate_manager_dns_authorization.apex.id]
  }
}

resource "google_certificate_manager_certificate_map" "edge" {
  name = "${var.namespace}-edge"

  depends_on = [google_project_service.apis]
}

# A single PRIMARY entry serves the certificate for every SNI. It covers the
# apex and every subdomain, so per-host entries would add nothing.
resource "google_certificate_manager_certificate_map_entry" "primary" {
  name         = "${var.namespace}-edge-primary"
  map          = google_certificate_manager_certificate_map.edge.name
  matcher      = "PRIMARY"
  certificates = [google_certificate_manager_certificate.edge.id]
}
