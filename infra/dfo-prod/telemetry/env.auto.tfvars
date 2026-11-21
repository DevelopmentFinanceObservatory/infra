# Values for this environment that the shared stack code in
# infra/stacks/telemetry declares with no default.
project_id = "prod-fin-observatory"
region     = "europe-west1"
namespace  = "dfo-prod"

# Days the dfo-prod-telemetry bucket keeps raw Cloud Run entries, and so how
# far back dfo_logs reaches. A year lets a new logs_daily column back-fill
# from the sink's start, and bounds how long raw IPs and user agents are held.
log_retention_days = 365

# Numeric GitHub id of DevelopmentFinanceObservatory/analytics. It enables the
# repository's CI and deploy Workload Identity bindings.
analytics_repository_id = "1464310463"

# The analytics Jobs, Scheduler triggers and alerts. The image is the one the
# analytics Deploy workflow pushed for main; the workflow moves the Jobs named
# in the repository variable ANALYTICS_JOBS to each later image.
analytics_jobs_enabled = true
analytics_jobs_image   = "europe-west1-docker.pkg.dev/prod-fin-observatory/analytics/dfo-analytics:23beaee9f8fab78caca8685546397676bf250136"
