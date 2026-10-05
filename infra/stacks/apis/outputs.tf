output "service_name" {
  description = "Cloud Run service name. dfo-apis's SERVICE_APIS in this environment's GitHub Environment."
  value       = module.apis_service.service_name
}

output "service_url" {
  description = "Cloud Run service URL."
  value       = module.apis_service.service_url
}

output "runtime_service_account_email" {
  description = "Email of the dedicated runtime service account the service runs as."
  value       = module.apis_service.runtime_service_account_email
}

output "psc_network_subnetwork_id" {
  description = "Self link of apis's PSC subnet (network.tf). The Cloud Run service's direct VPC egress already reads this same value from module.psc_network directly; this output exists for visibility to anyone debugging the service's network path from outside this stack."
  value       = module.psc_network.subnetwork_id
}

output "psc_network_endpoint_ip_address" {
  description = "Reserved internal IP address of apis's PSC endpoint, the host the Datasets API's database connection reaches Postgres at, as if it were the instance's own private IP. The address is dynamically allocated and the service's own env_vars do not read it, so without this output, whoever configures or debugs the connection has no way to find it, even though the module's private zone resolves the instance's PSC name to it."
  value       = module.psc_network.endpoint_ip_address
}
