variable "project_id" {
  description = "GCP project this environment deploys into."
  type        = string
}

variable "region" {
  description = "Default GCP region for regional resources."
  type        = string
}

variable "namespace" {
  description = "Prefix for this environment's resource names, such as dfo-dev."
  type        = string
}

variable "tier" {
  description = "Deployment tier this environment's website serves: staging in dfo-dev, production in dfo-prod. Staging resource names end in -staging; production names carry no tier."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.tier)
    error_message = "tier must be staging or production."
  }
}

variable "deployer_service_account" {
  description = "Email of dfo-website's CI image-deployer service account, which the foundation stack creates. Copied from that stack's output as a plain value; the data lookup in main.tf still fails the plan if the account does not exist."
  type        = string
}

variable "cloudsql_login_role_id" {
  description = "Id of this stack's project-scoped custom role for Cloud SQL IAM login without the Data API, such as dfoDevWebsiteCloudsqlLoginOnly. See database.tf."
  type        = string
}

variable "platform_psc_service_attachment_uri" {
  description = "Target URI of the shared Cloud SQL instance's PSC service attachment, copied from the platform stack's psc_service_attachment_uri output rather than read through remote state, so this stack's plan never depends on that stack having applied."
  type        = string
}

variable "platform_dns_name" {
  description = "The shared Cloud SQL instance's PSC DNS name, copied from the platform stack's dns_name output rather than read through remote state, so this stack's plan never depends on that stack having applied."
  type        = string
}

variable "platform_postgres_instance_name" {
  description = "Name of the shared Cloud SQL instance from the platform stack, copied from that stack's instance_name output rather than read through remote state, so this stack's plan never depends on that stack having applied."
  type        = string
}

variable "platform_postgres_connection_name" {
  description = "Cloud SQL connection name (project:region:instance) of the shared instance from the platform stack, the value the Cloud SQL connector resolves an instance from, copied from that stack's connection_name output rather than read through remote state, so this stack's plan never depends on that stack having applied."
  type        = string
}

variable "studio_api_base" {
  description = "Base URL of the ai stack's Cloud Run service, which the website's /api/studio/* proxy forwards requests to. Copied from the `ai` stack's `service_url` output rather than read through remote state, so this stack's plan never depends on that stack having applied."
  type        = string
}

variable "search_api_base" {
  description = "Base URL of the apis stack's Cloud Run service, which the website's search, datasets and graph proxies forward to. A bare host with no path suffix. Copied from the `apis` stack's `service_url` output rather than read through remote state, so this stack's plan never depends on that stack having applied. The service refuses to start without it."
  type        = string
}

variable "apis_service_name" {
  description = "Name of the apis stack's Cloud Run service, in this stack's project and region, on which this stack grants the website's runtime service account roles/run.invoker. Copied from the `apis` stack's `service_name` output. The apis stack applies before this one, so the service exists when this grant applies."
  type        = string
}

variable "website_url" {
  description = "The website service's own public URL. A module self-reference to module.website_service.service_url would cycle, since the module can't consume its own not-yet-created service's URL as one of its inputs, so this value is copied in as a literal instead."
  type        = string
}

variable "ingress" {
  description = "Which sources may reach the website's Cloud Run URL, passed to the cloud-run-service module's `ingress`. INGRESS_TRAFFIC_ALL accepts the internet. INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER accepts only the global external Application Load Balancer in front of the site, so requests to the run.app URL are refused."
  type        = string
  default     = "INGRESS_TRAFFIC_ALL"
}

variable "trusted_proxy_hops" {
  description = "How many proxies the website trusts to append to X-Forwarded-For, counted from the right, so the entry at that depth is the client address. Null omits the TRUSTED_PROXY_HOPS env var and the app uses its default of 0, the rightmost entry, which is what Google's front end appends on a bare run.app URL. Behind Cloudflare and the Google load balancer the header reads \"client, cloudflare-edge, lb\", so the client sits 2 hops from the right."
  type        = number
  default     = null

  validation {
    condition     = var.trusted_proxy_hops == null ? true : (var.trusted_proxy_hops >= 0 && floor(var.trusted_proxy_hops) == var.trusted_proxy_hops)
    error_message = "trusted_proxy_hops must be null or a whole number of at least 0."
  }
}

variable "datasets_pin_principal_secret_id" {
  description = "Secret Manager id of the datasets pin principal secret. Copied from the `apis` stack's `google_secret_manager_secret.datasets_pin_principal.secret_id`. A plain value keeps this stack's plan independent of whether the `apis` stack has created the secret yet, which a `data \"google_secret_manager_secret\"` lookup would not. See README."
  type        = string
}

variable "live_refresh_principal_secret_id" {
  description = "Secret Manager id of the live-refresh principal secret. Copied from the `apis` stack's `google_secret_manager_secret.live_refresh_principal.secret_id`. A plain value keeps this stack's plan independent of whether the `apis` stack has created the secret yet, which a `data \"google_secret_manager_secret\"` lookup would not. See README."
  type        = string
}

variable "posthog_key" {
  description = "PostHog project API key (public write-only token, see README \"PostHog telemetry\") for the DFO project on PostHog Cloud EU, org-managed in the PostHog UI rather than by Terraform."
  type        = string
}

variable "posthog_host" {
  description = "PostHog ingestion endpoint. The project lives on PostHog Cloud EU, so this is the EU ingest host."
  type        = string
  default     = "https://eu.i.posthog.com"
}

variable "stateless_deletion_protection" {
  description = "Deletion protection for this stack's Cloud Run services and Jobs, the same flag the dcp stack passes to its Cloud Run resources. They hold no data of their own, so this guards against an accidental destroy or replace rather than data loss. Off in dfo-dev, so `terraform destroy` and replaces stay unblocked; on in dfo-prod."
  type        = bool
}

variable "min_instances" {
  description = "Instances Cloud Run keeps warm for the website service. 0 lets it scale to zero, and the first request after an idle spell waits for a Next.js cold start. With cpu_idle, a warm instance bills at the idle rate between requests."
  type        = number
  default     = 0
}

variable "ses" {
  description = "The IAM role in ONE's SES account that this service assumes with its Google identity to send sign-in email through the Amazon SES API: the role's ARN, the account's region, and the ID token audience the role's trust policy requires. Null omits SES_ROLE_ARN, SES_REGION and SES_TOKEN_AUDIENCE, and the app offers no email sign-in. See README, \"Email sign-in\"."
  type = object({
    role_arn       = string
    region         = string
    token_audience = string
  })
  default = null

  validation {
    condition = var.ses == null ? true : (
      can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.ses.role_arn)) &&
      can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.ses.region)) &&
      can(regex("\\S", var.ses.token_audience))
    )
    error_message = "ses must be null or set role_arn to an IAM role ARN such as arn:aws:iam::123456789012:role/name, region to an AWS region such as us-east-1, and token_audience to a non-blank string."
  }
}

variable "turnstile_site_key" {
  description = "Site key of the Cloudflare Turnstile widget on the login page. The login page renders it, so it is public and passed as a plain env var. Null omits TURNSTILE_SITE_KEY, and the app offers no email sign-in. See README, \"Email sign-in\"."
  type        = string
  default     = null
}
