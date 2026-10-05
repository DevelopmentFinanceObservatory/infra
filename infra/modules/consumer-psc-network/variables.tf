variable "project_id" {
  description = "GCP project the VPC, subnet, and PSC endpoint live in."
  type        = string
}

variable "region" {
  description = "Region for the subnet and the PSC endpoint. Must match the shared Cloud SQL instance's region, since a forwarding rule can only target a service attachment in the same region."
  type        = string
}

variable "network_name" {
  description = "Name of the consumer's dedicated VPC network. Also the base for the subnet, reserved address, forwarding rule, and DNS zone names (\"<network_name>-subnet\", \"-endpoint\", \"-fwd\", \"-sql\")."
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR range for the consumer's subnet. No default, because every instantiation has to pick a range that doesn't overlap any other consumer's, in this environment or any other, since these VPCs could be peered later. See README.md for the range assignment."
  type        = string
}

variable "service_attachment_uri" {
  description = "Target URI of the shared Cloud SQL instance's PSC service attachment (its psc_service_attachment_uri output), for the forwarding rule to target. The instance's allowed_consumer_projects must also list this project, since an endpoint alone grants nothing."
  type        = string
}

variable "dns_name" {
  description = "The shared Cloud SQL instance's PSC DNS name (its dns_name attribute, copied from the platform stack's dns_name output), without a trailing dot. The module publishes a private zone answering for exactly this name inside the consumer's VPC, pointing at the PSC endpoint address, because the Cloud SQL connectors resolve this name rather than accepting an IP."
  type        = string

  validation {
    condition     = !endswith(var.dns_name, ".")
    error_message = "dns_name must not include a trailing dot; the module appends one itself."
  }
}
