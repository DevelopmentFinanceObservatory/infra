# Values for this environment that the shared stack code in
# infra/stacks/telemetry declares with no default.
project_id = "prod-fin-observatory"
region     = "europe-west1"
namespace  = "dfo-prod"

# Days the dfo-prod-telemetry bucket keeps raw Cloud Run entries, and so how
# far back dfo_logs reaches. A year lets a new analytics model back-fill
# from the sink's start, and bounds how long raw IPs and user agents are held.
log_retention_days = 365

# Numeric GitHub id of DevelopmentFinanceObservatory/analytics. It enables the
# repository's CI and deploy Workload Identity bindings.
analytics_repository_id = "1464310463"

# The analytics Jobs, Scheduler triggers and alerts. The image is the one the
# analytics Deploy workflow pushed for main; the workflow moves the Jobs named
# in the repository variable ANALYTICS_JOBS to each later image.
analytics_jobs_enabled = true
analytics_jobs_image   = "europe-west1-docker.pkg.dev/prod-fin-observatory/analytics/dfo-analytics:e7371e5adc6dab5df7fab3be90a4ce354639b74b"

# The hourly dbt build and its freshness Job run on their schedules, and so
# do the probes, the topics passes and the observation specs Job whose canary
# execution wrote valid rows. The citation probe stays off.
analytics_dbt_schedule_enabled = true
analytics_probes_enabled = {
  repos              = true
  lighthouse         = true
  replay             = true
  "call-specs"       = true
  "topics-variables" = true
  "topics-turns"     = true
  "topics-specs"     = true
}
