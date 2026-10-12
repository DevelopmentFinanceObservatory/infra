# Admits only requests carrying the origin secret from origin_secret.tf and
# denies the rest with a 403. Without it, anyone who finds the load
# balancer's address could reach the website around Cloudflare's rate limit
# and Access rules, including through a Cloudflare zone of their own pointed
# at the address. A serverless backend has no health checks for the default
# deny to block.
resource "google_compute_security_policy" "edge" {
  name        = "${var.namespace}-edge"
  description = "Admit only requests that came through the Cloudflare edge."
  type        = "CLOUD_ARMOR"

  rule {
    action      = "allow"
    priority    = 1000
    description = "Request carries the Cloudflare origin secret."

    match {
      expr {
        expression = "request.headers['${var.origin_auth_header_name}'] == '${local.origin_auth_header_value}'"
      }
    }
  }

  rule {
    action      = "deny(403)"
    priority    = 2147483647
    description = "Default: deny everything else."

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = ["*"]
      }
    }
  }

  depends_on = [google_project_service.apis]
}
