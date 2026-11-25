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
  # The edge-logs stack's Logpush filter lists the same prefixes in its own
  # dataset_path_prefixes, and the two lists must match.
  dataset_path_prefixes = ["/api/datasets/", "/api/v1/datasets/"]

  # The Pro plan has no regex, so the paths are matched with wildcard, which
  # ignores case and lets * span slashes. A dataset id starts spec_ and a
  # content version cv_. A digest file is
  # <prefix>spec_<id>/cv_<hex>/files/<digest>, and a manifest is exactly
  # <prefix>spec_<id>/cv_<hex>. A derived frame's file is
  # <prefix>derived/ops_<id>/ocv_<hex>/files/<digest>. Each pattern is paired
  # with a test that rules out a deeper path: nothing may follow the digest,
  # and the manifest has no third segment, which also excludes the /file
  # selector. A derived frame's manifest and selector stay uncached. Share
  # slot data is left out, since a share that is withdrawn has no purge path.
  # The heads route, exactly <prefix>heads, is a read-only lookup keyed by the
  # query string (?spec_id=...). It is matched with eq, which is case-exact,
  # and http.request.uri.path leaves out the query string, so each query is
  # cached under its own full-URI cache key. The origin sets Cache-Control:
  # public, max-age=300 on a 200 and no-store on a 400.
  edge_cache_path_match = join(" or ", concat(
    [for prefix in local.dataset_path_prefixes : "(http.request.uri.path wildcard \"${prefix}spec_*/cv_*/files/*\" and not http.request.uri.path wildcard \"${prefix}*/*/files/*/*\")"],
    [for prefix in local.dataset_path_prefixes : "(http.request.uri.path wildcard \"${prefix}spec_*/cv_*\" and not http.request.uri.path wildcard \"${prefix}*/*/*\")"],
    [for prefix in local.dataset_path_prefixes : "(http.request.uri.path wildcard \"${prefix}derived/ops_*/ocv_*/files/*\" and not http.request.uri.path wildcard \"${prefix}derived/*/*/files/*/*\")"],
    [for prefix in local.dataset_path_prefixes : "http.request.uri.path eq \"${prefix}heads\""],
  ))

  # A request with an Origin header is cross-origin, and its response carries
  # an Access-Control-Allow-Origin for that origin. Cloudflare's default cache
  # key includes the Origin header ("The Origin header is always included
  # unless explicitly excluded",
  # https://developers.cloudflare.com/cache/how-to/cache-keys/), so each
  # Origin value is cached as its own variant with the header the website sent
  # for it. This stack sets no custom cache key, and the rule must not set one
  # that excludes Origin, or one origin's header would reach another's pages.
  # A request with an Authorization header is not cache-eligible. Header names
  # keep their case on HTTP/1.1, hence lower(). A truncated header list may
  # have dropped the Authorization header, so it counts as authenticated.
  edge_cache_plain_request = "not http.request.headers.truncated and not any(lower(http.request.headers.names[*])[*] in {\"authorization\"})"

  # Only GET is cache-eligible. Cloudflare answers an eligible HEAD from a
  # cached GET and fetches a cold one from the origin as a GET
  # (https://developers.cloudflare.com/cache/concepts/cache-behavior/). The
  # Logpush job in infra/stacks/edge-logs/cloudflare_logpush.tf records GET
  # only, so a cached HEAD would be counted nowhere, and a cold one would
  # write a delivery line for a body no client received. A HEAD goes to the
  # website, which forwards it to dfo-apis uncached.
  edge_cache_get = "http.request.method eq \"GET\""

  # wildcard ignores case, and the Logpush filter in
  # infra/stacks/edge-logs/cloudflare_logpush.tf matches the prefixes as
  # written. This case-sensitive test keeps the cache to paths that filter
  # logs, so a read in another case goes to the website, whose own request log
  # records it.
  edge_cache_logged_path = join(" or ", [for prefix in local.dataset_path_prefixes : "starts_with(http.request.uri.path, \"${prefix}\")"])
}

# Makes the website's dataset files, dataset manifests, derived frames' files
# and heads lookups cache-eligible for reads with no Authorization header,
# from any origin.
# Cloudflare then follows the Cache-Control the website sends: a pinned digest
# file for a year, and a working file, a manifest and a derived frame's file
# for 300 s, and a heads lookup for the 300 s the origin sets.
# A response with no-store or with no Cache-Control is never
# stored. The website sets Cache-Tag to the content version on dataset
# responses, so a revoked version is purged by tag
# (infra/dfo-prod/edge/README.md, "Revoking a dataset version"). A revocation
# cannot yet name the derived frames computed from it, so their files expire
# from the edge within 300 s. Share slot
# data is not in the rule; the website serves it with its own Cache-Control.
#
# The rule exists only while var.edge_cache_enabled is true, and the
# precondition refuses that unless the edge-logs stack's Logpush job exists,
# is enabled, and has delivered. A read the cache answers never reaches the
# website, so without the job it would be counted nowhere.
#
# The job lives in its own stack because every Logpush API call needs Logs
# Write on the zone, reads included
# (https://developers.cloudflare.com/logs/logpush/permissions/), and both
# Logpush data sources accept only Logs Write
# (https://registry.terraform.io/providers/cloudflare/cloudflare/5.27.0/docs/data-sources/logpush_jobs).
# The list below is read only while the cache is on and
# var.edge_cache_logpush_check is true, which holds for every apply and for no
# pull-request plan, so a plan with the read-only token makes no Logpush call.
data "cloudflare_logpush_jobs" "zone" {
  count = var.edge_cache_enabled && var.edge_cache_logpush_check ? 1 : 0

  zone_id = var.cloudflare_zone_id
}

locals {
  # The edge-logs stack names its job dataset-reads, on http_requests.
  edge_logpush_dataset_reads = [
    for job in flatten(data.cloudflare_logpush_jobs.zone[*].result) : job
    if job.name == "dataset-reads" && job.dataset == "http_requests"
  ]
}

resource "cloudflare_ruleset" "cache" {
  count = var.edge_cache_enabled ? 1 : 0

  zone_id     = var.cloudflare_zone_id
  name        = "Cache"
  description = "Cache the website's dataset files, manifests, derived files and heads lookups for reads with no Authorization header."
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules = [
    {
      ref         = "datasets_plain_reads"
      description = "Cache dataset files, dataset manifests, derived frame files and heads lookups (/datasets/heads, under either prefix) for requests with no Authorization header, as the origin's Cache-Control says."
      expression  = "${local.edge_cache_get} and (${local.edge_cache_path_match}) and (${local.edge_cache_logged_path}) and ${local.edge_cache_plain_request}"
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

  # last_complete is the end of the newest period the job has delivered, and
  # stays empty until its first push. last_error and error_message are set
  # while the job is failing and cleared by its next successful push
  # (https://registry.terraform.io/providers/cloudflare/cloudflare/5.27.0/docs/data-sources/logpush_jobs).
  # A job created moments before has no last_complete yet, so the cache rule
  # waits for an apply after the job has delivered, and a job that delivered
  # once and is failing now refuses it too.
  lifecycle {
    precondition {
      condition = !var.edge_cache_logpush_check || (
        length(local.edge_logpush_dataset_reads) == 1 &&
        try(local.edge_logpush_dataset_reads[0].enabled, false) == true &&
        try(length(local.edge_logpush_dataset_reads[0].last_complete) > 0, false) &&
        try(coalesce(local.edge_logpush_dataset_reads[0].last_error, ""), "") == "" &&
        try(coalesce(local.edge_logpush_dataset_reads[0].error_message, ""), "") == ""
      )
      error_message = "edge_cache_enabled needs exactly one dataset-reads Logpush job on the zone, enabled, with a delivered push, and with no last_error or error_message, which Cloudflare sets while the job is failing: apply the edge-logs stack with edge_logpush_bucket set, and confirm lines arrive with scripts/check-edge-logpush.sh first (infra/dfo-prod/edge-logs/README.md)."
    }
  }
}

# A zone holds one entrypoint ruleset per phase, so the create above fails
# when the zone already has one for http_request_cache_settings. Check before
# the first apply (infra/dfo-prod/edge/README.md, "Before the first apply").
# When that check lists an entrypoint, uncomment this block and put its id
# in place of <ruleset id>, as for the redirects ruleset above. The name and
# kind in the resource must then match the existing entrypoint, since a
# change would replace it.
# import {
#   to = cloudflare_ruleset.cache[0]
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
