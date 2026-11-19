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

locals {
  # Both prefixes of the Datasets API reach one handler (the website rewrites
  # /api/datasets onto /api/v1/datasets), but Cloudflare sees the path the
  # browser sent. The SDK reads a manifest under /api/v1/datasets and a file
  # at the manifest's own url, under /api/datasets.
  dataset_path_prefixes = ["/api/datasets/", "/api/v1/datasets/"]

  # The Pro plan has no regex, so the paths are matched with wildcard, which
  # ignores case and lets * span slashes. A dataset id starts spec_ and a
  # content version cv_. A digest file is
  # <prefix>spec_<id>/cv_<hex>/files/<digest>, and a manifest is exactly
  # <prefix>spec_<id>/cv_<hex>. Each pattern is paired with a test that rules
  # out a deeper path: nothing may follow the digest, and the manifest has no
  # third segment, which also excludes the /file selector. Share slot data is
  # left out, since a share that is withdrawn has no purge path.
  edge_cache_path_match = join(" or ", concat(
    [for prefix in local.dataset_path_prefixes : "(http.request.uri.path wildcard \"${prefix}spec_*/cv_*/files/*\" and not http.request.uri.path wildcard \"${prefix}*/*/files/*/*\")"],
    [for prefix in local.dataset_path_prefixes : "(http.request.uri.path wildcard \"${prefix}spec_*/cv_*\" and not http.request.uri.path wildcard \"${prefix}*/*/*\")"],
  ))

  # A request with an Origin header is cross-origin, and its response carries
  # an Access-Control-Allow-Origin for that origin. Cloudflare's cache ignores
  # Vary: Origin, so such a response must never be stored. A same-origin GET
  # carries no Origin, so pages on the apex still get the cache. A request
  # with an Authorization header is not cache-eligible either. Header names
  # keep their case on HTTP/1.1, hence lower(). A truncated header list may
  # have dropped either header, so it counts as cross-origin and
  # authenticated.
  edge_cache_plain_request = "not http.request.headers.truncated and not any(lower(http.request.headers.names[*])[*] in {\"origin\" \"authorization\"})"
}

# Makes the website's dataset files and dataset manifests cache-eligible for
# same-origin reads with no Authorization header. Cloudflare then follows the
# Cache-Control the website sends: a pinned digest file for a year, and a
# working file and a manifest for 300 s. A response with no-store or with no
# Cache-Control is never stored. The website sets Cache-Tag to the content
# version on dataset responses, so a revoked version is purged by tag
# (infra/dfo-prod/edge/README.md, "Revoking a dataset version"). Share slot
# data is not in the rule; the website serves it with its own Cache-Control.
resource "cloudflare_ruleset" "cache" {
  zone_id     = var.cloudflare_zone_id
  name        = "Cache"
  description = "Cache the website's dataset files and manifests for same-origin reads."
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules = [
    {
      ref         = "datasets_same_origin"
      description = "Cache dataset files and dataset manifests for requests with no Origin or Authorization header, as the origin's Cache-Control says."
      expression  = "(${local.edge_cache_path_match}) and ${local.edge_cache_plain_request}"
      action      = "set_cache_settings"
      action_parameters = {
        cache = true
        # Follow the origin's Cache-Control, and store nothing when the
        # response has none. Cloudflare's default TTL for the status code
        # would otherwise cache a response the website did not mark.
        edge_ttl = {
          mode = "bypass_by_default"
        }
        browser_ttl = {
          mode = "respect_origin"
        }
      }
    },
  ]
}

# A zone holds one entrypoint ruleset per phase, so the create above fails
# when the zone already has one for http_request_cache_settings. Check before
# the first apply (infra/dfo-prod/edge/README.md, "Before the first apply").
# When that check lists an entrypoint, uncomment this block and put its id
# in place of <ruleset id>, as for the redirects ruleset above. The name and
# kind in the resource must then match the existing entrypoint, since a
# change would replace it.
# import {
#   to = cloudflare_ruleset.cache
#   id = "zones/${var.cloudflare_zone_id}/<ruleset id>"
# }

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
