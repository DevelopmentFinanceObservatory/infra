# Cloudflare Access in front of the preview host, so only the team reaches it
# during rehearsal. Sign-in uses the account's existing Zero Trust
# organisation and identity providers, which this stack leaves alone.
#
# The application is zone-scoped and carries its policy inline. Reusable
# Access policies are account-scoped, and the stack's token has zone
# permissions only.
resource "cloudflare_zero_trust_access_application" "preview" {
  zone_id          = var.cloudflare_zone_id
  name             = "DFO preview"
  type             = "self_hosted"
  session_duration = "24h"

  destinations = [
    {
      type = "public"
      uri  = local.preview_host
    },
  ]

  policies = [
    {
      name       = "Allow the preview list"
      decision   = "allow"
      precedence = 1
      # Each include entry holds one rule, and a user who matches any of
      # them is let in.
      include = concat(
        [for domain in var.preview_access_email_domains : { email_domain = { domain = domain } }],
        [for email in var.preview_access_emails : { email = { email = email } }],
      )
    },
  ]
}
