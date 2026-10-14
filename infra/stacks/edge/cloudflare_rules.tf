# Zone rulesets, one per phase. Each is the phase's entrypoint ruleset: a
# zone holds at most one per phase, so a phase that already has one is
# imported.

locals {
  # The hosts whose requests reach the load balancer. The redirect below
  # answers www at the edge, so it stays out. The apex carries the origin header
  # from the first apply, so until serve_from_lb flips it also reaches the
  # holding-page load balancer in one-data-commons. That is ONE's own origin,
  # and the exposure is accepted.
  origin_hosts = [var.domain, local.preview_host, local.mcp_host]

  # The website's data API routes, which it proxies to the search, datasets
  # and graph backends. The legacy /api/<name> prefixes rewrite onto the same
  # handlers. /mcp has no edge limit: MCP connectors such as Claude.ai and
  # ChatGPT call it from a few shared provider egress addresses, so a per-IP
  # limit would block every user of a connector at once.
  api_path_prefixes = [
    "/api/v1/",
    "/api/search",
    "/api/datasets",
    "/api/graph",
  ]

  # Studio's routes. Each turn runs the model harness, so they have a lower
  # limit of their own.
  studio_path_prefixes = [
    "/api/v1/studio",
    "/api/studio",
  ]

  # The path is lowercased before the prefix match because Next.js routes
  # case-insensitively, so /API/SEARCH/resolve reaches the API handler too.
  api_path_match    = join(" or ", [for prefix in local.api_path_prefixes : "starts_with(lower(http.request.uri.path), \"${prefix}\")"])
  studio_path_match = join(" or ", [for prefix in local.studio_path_prefixes : "starts_with(lower(http.request.uri.path), \"${prefix}\")"])

  # The longest counting period the Pro plan allows, and a block well inside
  # its one-hour ceiling.
  rate_limit_period_seconds = 60
  rate_limit_block_seconds  = 600

  # Cloudflare's managed rulesets, which have the same ids in every zone.
  cloudflare_managed_ruleset_id = "efb7b8c949ac4650a09736fc376e9aee"
  owasp_core_ruleset_id         = "4814384a9e5d4991b9815dcfc25d2f1f"
  # 949110, the OWASP rule that acts once a request's score passes the
  # threshold. The other rules in that ruleset only add to the score.
  owasp_anomaly_rule_id = "6179ae15870a4bb7b2d480d4843b323c"
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
    {
      ref         = "mcp_host_to_apex"
      description = "Redirect every path on the MCP host except /mcp to the apex, keeping the path and query."
      expression  = "http.host eq \"${local.mcp_host}\" and not starts_with(lower(http.request.uri.path), \"/mcp\")"
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

# The Pro plan allows two rate-limit rules, each counting per IP and colo.
# The two expressions are disjoint, so a request counts against one rule.
resource "cloudflare_ruleset" "rate_limit" {
  zone_id     = var.cloudflare_zone_id
  name        = "Rate limit"
  description = "Per-IP rate limits on the website's data API and Studio routes."
  kind        = "zone"
  phase       = "http_ratelimit"

  rules = [
    {
      ref         = "studio_per_ip"
      description = "Block an IP for ${local.rate_limit_block_seconds} s after ${var.edge_studio_requests_per_minute} Studio requests in ${local.rate_limit_period_seconds} s."
      expression  = local.studio_path_match
      action      = "block"
      ratelimit = {
        characteristics     = ["ip.src", "cf.colo.id"]
        period              = local.rate_limit_period_seconds
        requests_per_period = var.edge_studio_requests_per_minute
        mitigation_timeout  = local.rate_limit_block_seconds
      }
    },
    {
      ref         = "api_per_ip"
      description = "Block an IP for ${local.rate_limit_block_seconds} s after ${var.edge_api_requests_per_minute} data API requests in ${local.rate_limit_period_seconds} s."
      expression  = "(${local.api_path_match}) and not (${local.studio_path_match})"
      action      = "block"
      ratelimit = {
        characteristics     = ["ip.src", "cf.colo.id"]
        period              = local.rate_limit_period_seconds
        requests_per_period = var.edge_api_requests_per_minute
        mitigation_timeout  = local.rate_limit_block_seconds
      }
    },
  ]
}

# The Cloudflare Managed Ruleset runs at its default actions. The OWASP Core
# Ruleset scores each request against generic attack patterns and flags
# query-like text, which Studio and the data API carry, so its anomaly rule
# logs where it would block. Deployed through the API it runs every paranoia
# level, so the overrides leave level 1 alone and turn the rest off.
resource "cloudflare_ruleset" "managed_waf" {
  zone_id     = var.cloudflare_zone_id
  name        = "Managed WAF"
  description = "Cloudflare's managed rulesets."
  kind        = "zone"
  phase       = "http_request_firewall_managed"

  rules = [
    {
      ref         = "cloudflare_managed"
      description = "Run the Cloudflare Managed Ruleset."
      expression  = "true"
      action      = "execute"
      action_parameters = {
        id = local.cloudflare_managed_ruleset_id
      }
    },
    {
      ref         = "owasp_core_log"
      description = "Run the OWASP Core Ruleset at paranoia level 1, logging requests it would block."
      expression  = "true"
      action      = "execute"
      action_parameters = {
        id = local.owasp_core_ruleset_id
        overrides = {
          categories = [
            for level in [2, 3, 4] : {
              category = "paranoia-level-${level}"
              enabled  = false
            }
          ]
          rules = [
            {
              id     = local.owasp_anomaly_rule_id
              action = "log"
            },
          ]
        }
      }
    },
  ]
}
