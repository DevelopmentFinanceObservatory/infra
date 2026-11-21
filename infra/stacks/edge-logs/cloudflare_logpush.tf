# Cloudflare Logpush of every edge request on the dataset read routes, cache
# hits included, unsampled, to the telemetry stack's edge_logs bucket. The
# website's request log never sees a read Cloudflare answers from its cache,
# so these lines are the only record of those uses. Everything here exists
# only while var.edge_logpush_bucket is set, and the edge stack's cache rule
# (infra/stacks/edge/cloudflare_rules.tf) refuses to exist without the job.
#
# Every Logpush API call needs Logs Write on the zone, reads included
# (https://developers.cloudflare.com/logs/logpush/permissions/), so this stack
# plans and applies only with the production environment's token, and no
# pull-request plan runs it.

locals {
  edge_logpush = var.edge_logpush_bucket != null

  # The dataset read prefixes, as the browser sends them. The website rewrites
  # /api/datasets onto /api/v1/datasets, but Cloudflare sees the path as sent.
  # dataset_path_prefixes in infra/stacks/edge/cloudflare_rules.tf must list
  # the same prefixes, since the cache rule may serve only paths this job logs.
  dataset_path_prefixes = ["/api/datasets/", "/api/v1/datasets/"]

  # {DATE} becomes the UTC day as YYYYMMDD, one directory a day
  # (https://developers.cloudflare.com/logs/logpush/logpush-job/api-configuration/).
  edge_logpush_destination = "gs://${coalesce(var.edge_logpush_bucket, "unset")}/http_requests/{DATE}"

  # Request headers logged through the custom fields below, in lower case as
  # Cloudflare requires. Origin names the site a browser read came from, and
  # x-dfo-client the SDK or tool that sent it.
  edge_logpush_request_headers = ["origin", "x-dfo-client"]

  # GET on either dataset prefix, from any host. The Logpush filter has no
  # case-insensitive operator
  # (https://developers.cloudflare.com/logs/logpush/logpush-job/filters/), so
  # the cache rule adds the same case-sensitive prefix test, and every path
  # Cloudflare can answer from its cache is a path this job logs.
  edge_logpush_filter = jsonencode({
    where = {
      and = [
        { key = "ClientRequestMethod", operator = "eq", value = "GET" },
        { or = [for prefix in local.dataset_path_prefixes : { key = "ClientRequestPath", operator = "startsWith", value = prefix }] },
      ]
    }
  })

  # http_requests fields
  # (https://developers.cloudflare.com/logs/logpush/logpush-job/datasets/zone/http_requests/).
  # ClientRequestPath has no query string. The only dataset read with a query
  # is the /file selector, which the cache rule leaves uncached, so the
  # website's own request log carries its format. RequestHeaders holds the
  # custom fields.
  edge_logpush_fields = [
    "EdgeStartTimestamp",
    "RayID",
    "ClientRequestMethod",
    "ClientRequestHost",
    "ClientRequestPath",
    "ClientRequestReferer",
    "ClientRequestUserAgent",
    "ClientIP",
    "ClientCountry",
    "CacheCacheStatus",
    "EdgeResponseStatus",
    "EdgeResponseBytes",
    "OriginResponseStatus",
    "RequestHeaders",
  ]
}

# Custom fields put the listed request headers in each line's RequestHeaders
# object. The rule must have the expression "true", and the configuration
# applies to every http_requests job on the zone
# (https://developers.cloudflare.com/logs/logpush/logpush-job/custom-fields/).
# A zone holds one entrypoint ruleset per phase, so check for an existing one
# before the first apply, as infra/dfo-prod/edge-logs/README.md, "Before the
# first apply", shows.
resource "cloudflare_ruleset" "log_custom_fields" {
  count = local.edge_logpush ? 1 : 0

  zone_id     = var.cloudflare_zone_id
  name        = "Log custom fields"
  description = "Request headers Logpush adds to each http_requests line."
  kind        = "zone"
  phase       = "http_log_custom_fields"

  rules = [
    {
      ref         = "dataset_read_headers"
      description = "Log the Origin and X-DFO-Client request headers."
      expression  = "true"
      action      = "log_custom_field"
      action_parameters = {
        request_fields = [for name in local.edge_logpush_request_headers : { name = name }]
      }
    },
  ]
}

# Cloudflare writes ownership-challenge-<random>.txt to the destination and
# answers with its path. The job must present the token inside it
# (https://developers.cloudflare.com/logs/logpush/logpush-job/logpush-ownership-challenge/).
# The bucket's delete rule leaves .txt objects alone, so the file stays for
# every later plan's read below.
#
# The token expires seven days after it is issued, but the challenge stays in
# state, so a job deleted outside Terraform is recreated with an expired token
# and the create fails. Terraform cannot tie the challenge to the job's
# recreation: replace_triggered_by fires on an update or a replacement, not on
# a create, and a reference from the challenge to the job would be a cycle.
# Raising var.edge_logpush_challenge_generation replaces the challenge instead,
# and the job takes the new token in the same apply
# (infra/dfo-prod/edge-logs/README.md, "Renewing the ownership challenge").
resource "terraform_data" "edge_logpush_challenge_generation" {
  count = local.edge_logpush ? 1 : 0

  input = var.edge_logpush_challenge_generation
}

resource "cloudflare_logpush_ownership_challenge" "edge_logs" {
  count = local.edge_logpush ? 1 : 0

  zone_id          = var.cloudflare_zone_id
  destination_conf = local.edge_logpush_destination

  lifecycle {
    replace_triggered_by = [terraform_data.edge_logpush_challenge_generation[count.index]]
  }
}

data "google_storage_bucket_object_content" "edge_logpush_challenge" {
  count = local.edge_logpush ? 1 : 0

  bucket = var.edge_logpush_bucket
  name   = trimprefix(cloudflare_logpush_ownership_challenge.edge_logs[0].filename, "/")
}

resource "cloudflare_logpush_job" "dataset_reads" {
  count = local.edge_logpush ? 1 : 0

  zone_id             = var.cloudflare_zone_id
  name                = "dataset-reads"
  dataset             = "http_requests"
  enabled             = true
  destination_conf    = local.edge_logpush_destination
  ownership_challenge = trimspace(data.google_storage_bucket_object_content.edge_logpush_challenge[0].content)
  filter              = local.edge_logpush_filter

  # An update replaces output_options whole, so every option is set here
  # (https://developers.cloudflare.com/logs/logpush/logpush-job/log-output-options/).
  # The API's default timestamp format is unixnano.
  output_options = {
    output_type      = "ndjson"
    field_names      = local.edge_logpush_fields
    timestamp_format = "rfc3339"
    sample_rate      = 1
    cve_2021_44228   = false
  }

  # The job's lines carry RequestHeaders only once the custom fields exist.
  depends_on = [cloudflare_ruleset.log_custom_fields]
}

output "edge_logpush_job_id" {
  description = "Id of the Logpush job that writes dataset-read request lines, or null while edge_logpush_bucket is unset."
  value       = one(cloudflare_logpush_job.dataset_reads[*].id)
}
