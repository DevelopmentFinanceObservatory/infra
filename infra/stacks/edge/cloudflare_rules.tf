# Zone rulesets, one per phase. Each is the phase's entrypoint ruleset: a
# zone holds at most one per phase, so a phase that already has one is
# imported.

locals {
  # The hosts whose requests reach the load balancer. The redirect below
  # answers www at the edge, so it stays out. The apex carries the origin header
  # from the first apply, so until serve_from_lb flips it also reaches the
  # holding-page load balancer in one-data-commons. That is ONE's own origin,
  # and the exposure is accepted.
  origin_hosts = [var.domain, local.preview_host]

  # The website's API routes, which it proxies to the search and studio
  # backends. The legacy /api/<name> prefixes rewrite onto the same handlers.
  # /mcp is left out: MCP connectors such as Claude.ai and ChatGPT call it
  # from a few shared provider egress addresses, so a per-IP limit would
  # block every user of a connector at once.
  rate_limited_path_prefixes = [
    "/api/v1/",
    "/api/search",
    "/api/datasets",
    "/api/graph",
    "/api/studio",
  ]
}

# Adds the origin secret from origin_secret.tf to every request bound for the
# load balancer, which the Cloud Armor policy in armor.tf requires. The
# expression names the hosts so that a later proxied record pointing at
# another origin never receives the secret. Anyone who can read Transform
# Rules on the zone can also read the value here.
resource "cloudflare_ruleset" "origin_auth" {
  zone_id     = var.cloudflare_zone_id
  name        = "Origin auth"
  description = "Add the origin secret the load balancer's Cloud Armor policy requires."
  kind        = "zone"
  phase       = "http_request_late_transform"

  rules = [
    {
      ref         = "origin_auth_header"
      description = "Add the origin secret header."
      expression  = "http.host in {${join(" ", formatlist("%q", local.origin_hosts))}}"
      action      = "rewrite"
      action_parameters = {
        headers = {
          (var.origin_auth_header_name) = {
            operation = "set"
            value     = local.origin_auth_header_value
          }
        }
      }
    },
  ]
}

# The zone's entrypoint for this phase is empty and named "default".
# Changing the name or kind would replace the ruleset, so both match it.
import {
  to = cloudflare_ruleset.redirects
  id = "zones/${var.cloudflare_zone_id}/18fcf28e8e184da7913657eca0e726b9"
}

resource "cloudflare_ruleset" "redirects" {
  zone_id = var.cloudflare_zone_id
  name    = "default"
  kind    = "zone"
  phase   = "http_request_dynamic_redirect"

  rules = [
    {
      ref         = "www_to_apex"
      description = "Redirect www to the apex, keeping the path and query."
      expression  = "http.host eq \"www.${var.domain}\""
      action      = "redirect"
      action_parameters = {
        from_value = {
          status_code           = 301
          preserve_query_string = true
          target_url = {
            expression = "concat(\"https://${var.domain}\", http.request.uri.path)"
          }
        }
      }
    },
  ]
}

# The Free plan allows one rate-limit rule, matching on the path only,
# counting per IP and colo, with a 10 s period and a 10 s block. Splitting
# the limit by endpoint needs Pro (ONEcampaign/dfo-infra#253). The path is
# lowercased before the prefix match because Next.js routes case-insensitively,
# so /API/SEARCH/resolve reaches the API handler too.
resource "cloudflare_ruleset" "rate_limit" {
  zone_id     = var.cloudflare_zone_id
  name        = "Rate limit"
  description = "Per-IP rate limit on the website's API routes."
  kind        = "zone"
  phase       = "http_ratelimit"

  rules = [
    {
      ref         = "api_per_ip"
      description = "Block an IP for 10 s after ${var.edge_rate_limit_requests_per_10s} API requests in 10 s."
      expression  = join(" or ", [for prefix in local.rate_limited_path_prefixes : "starts_with(lower(http.request.uri.path), \"${prefix}\")"])
      action      = "block"
      ratelimit = {
        characteristics     = ["ip.src", "cf.colo.id"]
        period              = 10
        requests_per_period = var.edge_rate_limit_requests_per_10s
        mitigation_timeout  = 10
      }
    },
  ]
}
