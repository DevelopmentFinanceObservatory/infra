# DNS records in the developmentfinance.org Cloudflare zone. The two TXT
# records (MS= and _gh-developmentfinanceobservatory-o) stay unmanaged.

locals {
  # devfinance-redirect-ip in the one-data-commons project: the load balancer
  # behind the holding page, which also redirects www to the apex today. It
  # must stay up while serve_from_lb can still be flipped back to false.
  holding_page_ipv4 = "35.186.240.63"

  site_ipv4    = var.serve_from_lb ? google_compute_global_address.edge.address : local.holding_page_ipv4
  preview_host = "preview.${var.domain}"
  mcp_host     = "mcp.${var.domain}"
}

# Import adopts the apex and www records in place. They point at the holding
# page, and the ids are Cloudflare's record ids.
import {
  to = cloudflare_dns_record.apex
  id = "${var.cloudflare_zone_id}/ce11f2bf76c2e290130cdedad6fb50bd"
}

import {
  to = cloudflare_dns_record.www
  id = "${var.cloudflare_zone_id}/046da6bebb3b26498659817757c550f1"
}

resource "cloudflare_dns_record" "apex" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain
  type    = "A"
  content = local.site_ipv4
  proxied = true
  ttl     = 1
  comment = "Managed by Terraform: infra/stacks/edge"
}

# Proxied so Cloudflare answers it. The redirect in cloudflare_rules.tf sends
# every request to the apex before it reaches an origin.
resource "cloudflare_dns_record" "www" {
  zone_id = var.cloudflare_zone_id
  name    = "www.${var.domain}"
  type    = "A"
  content = local.site_ipv4
  proxied = true
  ttl     = 1
  comment = "Managed by Terraform: infra/stacks/edge"
}

# The rehearsal host. It points at the load balancer regardless of
# serve_from_lb, and Access in cloudflare_access.tf admits only the allow list.
resource "cloudflare_dns_record" "preview" {
  zone_id = var.cloudflare_zone_id
  name    = local.preview_host
  type    = "A"
  content = google_compute_global_address.edge.address
  proxied = true
  ttl     = 1
  comment = "Managed by Terraform: infra/stacks/edge"
}

# A second address for the MCP endpoint, so https://mcp.<domain>/mcp works
# as well as https://<domain>/mcp. The redirect in cloudflare_rules.tf sends
# every other path on this host to the apex.
resource "cloudflare_dns_record" "mcp" {
  zone_id = var.cloudflare_zone_id
  name    = local.mcp_host
  type    = "A"
  content = google_compute_global_address.edge.address
  proxied = true
  ttl     = 1
  comment = "Managed by Terraform: infra/stacks/edge"
}

# The CNAME Certificate Manager checks before it issues the load balancer's
# certificate. Unproxied, because Google must resolve it to its own target.
# Google returns both names with a trailing dot.
resource "cloudflare_dns_record" "certificate_authorization" {
  zone_id = var.cloudflare_zone_id
  name    = trimsuffix(google_certificate_manager_dns_authorization.apex.dns_resource_record[0].name, ".")
  type    = google_certificate_manager_dns_authorization.apex.dns_resource_record[0].type
  content = trimsuffix(google_certificate_manager_dns_authorization.apex.dns_resource_record[0].data, ".")
  proxied = false
  ttl     = 1
  comment = "Managed by Terraform: infra/stacks/edge"
}
