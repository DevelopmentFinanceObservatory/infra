# The ai stack's private network path to the shared Cloud SQL instance in
# the platform stack. The instance binds to no VPC and instead publishes a
# Private Service Connect service attachment, so reachability is each
# consumer's own resource. See
# infra/modules/consumer-psc-network/README.md for the subnet range table and
# the no-NAT/no-firewall rationale. `apis` and `website` already own one of
# these. This service's runtime identity needs the same path because it
# holds a `CLOUD_IAM_SERVICE_ACCOUNT` Postgres user for ADK's session store
# (session_store.tf).

# Copied from the platform stack's psc_service_attachment_uri output into
# env.auto.tfvars as a plain value, the same rationale variables.tf records for this stack's
# other cross-stack values: a literal value keeps this stack's plan from ever
# depending on platform having applied.
variable "platform_psc_service_attachment_uri" {
  description = "Target URI of the shared Cloud SQL instance's PSC service attachment, copied from the platform stack's psc_service_attachment_uri output."
  type        = string
}

# Same copy-as-literal-value rationale as platform_psc_service_attachment_uri
# above, copied from the platform stack's dns_name output.
variable "platform_dns_name" {
  description = "The shared Cloud SQL instance's PSC DNS name, copied from the platform stack's dns_name output."
  type        = string
}

# compute.googleapis.com, which the network, subnet, address, and forwarding
# rule below all need, is already enabled project-wide by the dcp and website
# stacks. dns.googleapis.com has no other enabler in this stack, so it
# declares it for the module's private zone and record set. See README.md's
# "APIs" section.
resource "google_project_service" "dns" {
  project            = var.project_id
  service            = "dns.googleapis.com"
  disable_on_destroy = false
}

# The instance authorises this project on its side; this forwarding rule is
# the other half. Neither one alone grants a connection.
module "psc_network" {
  source = "../../modules/consumer-psc-network"

  project_id = var.project_id
  region     = var.region

  network_name = "${var.namespace}-ai-psc"
  subnet_cidr  = "10.100.4.0/24"

  service_attachment_uri = var.platform_psc_service_attachment_uri
  dns_name               = var.platform_dns_name

  depends_on = [google_project_service.dns]
}
