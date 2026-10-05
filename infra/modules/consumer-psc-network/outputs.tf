output "network_id" {
  description = "Self link of the consumer's VPC network."
  value       = google_compute_network.this.id
}

output "subnetwork_id" {
  description = "Self link of the consumer's subnet, for the Cloud Run service's direct VPC egress configuration."
  value       = google_compute_subnetwork.this.id
}

output "endpoint_ip_address" {
  description = "Reserved internal IP address of the PSC endpoint. Consumer services connect to this address as if it were the instance's own private IP."
  value       = google_compute_address.psc_endpoint.address
}

output "forwarding_rule_id" {
  description = "Self link of the PSC endpoint's forwarding rule."
  value       = google_compute_forwarding_rule.psc_endpoint.id
}
