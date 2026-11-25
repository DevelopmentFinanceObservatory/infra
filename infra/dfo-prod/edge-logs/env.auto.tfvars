# Values for this environment that the shared stack code in
# infra/stacks/edge-logs declares with no default.
project_id         = "prod-fin-observatory"
cloudflare_zone_id = "e837f8819d4b16dce14e17cbe6ba3716"

# The telemetry stack's edge_logs_bucket output. Setting it creates the
# dataset-reads Logpush job (infra/dfo-prod/edge-logs/README.md, "Apply order").
edge_logpush_bucket = "dfo-prod-edge-logs-prod-fin-observatory"
