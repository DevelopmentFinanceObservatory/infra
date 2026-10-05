output "instance_name" {
  description = "Name of the shared Cloud SQL instance."
  value       = google_sql_database_instance.platform.name
}

output "connection_name" {
  description = "Cloud SQL connection name (project:region:instance), for tools that connect through the Cloud SQL Auth Proxy or connector libraries rather than a direct PSC endpoint."
  value       = google_sql_database_instance.platform.connection_name
}

output "psc_service_attachment_uri" {
  description = "URI of the instance's Private Service Connect service attachment. Consumer stacks target this from their own forwarding rule. It grants nothing on its own without a matching entry in allowed_consumer_projects."
  value       = google_sql_database_instance.platform.psc_service_attachment_link
}

output "dns_name" {
  description = "Instance's PSC DNS name. Consumer stacks copy this into their private zone (consumer-psc-network's dns_name input) so the Cloud SQL connectors can resolve it inside their VPC. The trailing dot the API returns is stripped here, so the value pastes straight into that variable."
  value       = trimsuffix(google_sql_database_instance.platform.dns_name, ".")
}

output "applier_db_user" {
  description = "Cloud SQL username of the dfo-infra-applier IAM database user, for tenant stacks that grant it privileges on their own database (e.g. to run a google_sql_provision_script)."
  value       = google_sql_user.applier.name
}
