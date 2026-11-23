# Values for this environment that the shared stack code in
# infra/stacks/edge declares with no default.
project_id           = "prod-fin-observatory"
region               = "europe-west1"
namespace            = "dfo-prod"
domain               = "developmentfinance.org"
website_service_name = "dfo-prod-website"

cloudflare_zone_id = "e837f8819d4b16dce14e17cbe6ba3716"
serve_from_lb      = true
# Cloudflare counts cache hits and the website's own 429s against this, and
# readers behind one office or campus address share it. 1,200 sits well above
# the website's per-address allowances (300 a minute for dataset reads, 120
# for the rest of /api), so a reader meets the website's 429 first.
edge_api_requests_per_minute    = 1200
edge_studio_requests_per_minute = 60
preview_access_email_domains    = ["one.org", "ode.partners"]

# Caches the gateway's dataset files and manifests at the edge. The cache
# rule's precondition refuses this until the edge-logs Logpush job has
# delivered (infra/dfo-prod/edge/README.md).
edge_cache_enabled = true
