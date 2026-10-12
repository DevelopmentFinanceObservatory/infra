output "lb_ipv4" {
  description = "The load balancer's IPv4 address, which Cloudflare's proxied records point at."
  value       = google_compute_global_address.edge.address
}

output "dns_authorization_record" {
  description = "The CNAME Certificate Manager checks before it issues the certificate. It must exist in Cloudflare, unproxied."
  value = {
    name = google_certificate_manager_dns_authorization.apex.dns_resource_record[0].name
    type = google_certificate_manager_dns_authorization.apex.dns_resource_record[0].type
    data = google_certificate_manager_dns_authorization.apex.dns_resource_record[0].data
  }
}

output "certificate_map_id" {
  description = "The Certificate Manager map the HTTPS proxy serves."
  value       = google_certificate_manager_certificate_map.edge.id
}

output "origin_auth_header_name" {
  description = "Request header that carries the origin secret."
  value       = var.origin_auth_header_name
}

output "origin_auth_header_value" {
  description = "The origin secret, for a direct request to the load balancer that bypasses Cloudflare."
  value       = local.origin_auth_header_value
  sensitive   = true
}
