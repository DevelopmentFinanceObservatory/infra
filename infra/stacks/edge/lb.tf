# Global external Application Load Balancer in front of the website's Cloud
# Run service. Cloudflare's proxied DNS records point at its address.
#
# It listens on 443 only. Cloudflare's Always Use HTTPS redirects plain HTTP
# at the edge and connects to the origin over HTTPS, so a port-80 listener
# would serve nobody.

resource "google_compute_global_address" "edge" {
  name       = "${var.namespace}-edge"
  ip_version = "IPV4"

  depends_on = [google_project_service.apis]
}

resource "google_compute_region_network_endpoint_group" "website" {
  name                  = "${var.namespace}-edge-website"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = var.website_service_name
  }

  depends_on = [google_project_service.apis]
}

# A serverless backend takes no timeout or health check. The Cloud Run
# service's own request timeout applies.
resource "google_compute_backend_service" "website" {
  name                  = "${var.namespace}-edge-website"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTPS"
  security_policy       = google_compute_security_policy.edge.id

  backend {
    group = google_compute_region_network_endpoint_group.website.id
  }

  log_config {
    enable      = true
    sample_rate = var.lb_log_sample_rate
  }
}

resource "google_compute_url_map" "edge" {
  name            = "${var.namespace}-edge"
  default_service = google_compute_backend_service.website.id
}

resource "google_compute_target_https_proxy" "edge" {
  name            = "${var.namespace}-edge"
  url_map         = google_compute_url_map.edge.id
  certificate_map = "//certificatemanager.googleapis.com/${google_certificate_manager_certificate_map.edge.id}"
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "${var.namespace}-edge-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_protocol           = "TCP"
  port_range            = "443"
  ip_address            = google_compute_global_address.edge.id
  target                = google_compute_target_https_proxy.edge.id
}
