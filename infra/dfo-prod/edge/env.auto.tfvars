# Values for this environment that the shared stack code in
# infra/stacks/edge declares with no default.
project_id           = "prod-fin-observatory"
region               = "europe-west1"
namespace            = "dfo-prod"
domain               = "developmentfinance.org"
website_service_name = "dfo-prod-website"

cloudflare_zone_id               = "e837f8819d4b16dce14e17cbe6ba3716"
serve_from_lb                    = false
edge_rate_limit_requests_per_10s = 100
preview_access_email_domains     = ["one.org", "ode.partners"]
preview_access_emails            = ["mikolaj@huncwot.com"]
