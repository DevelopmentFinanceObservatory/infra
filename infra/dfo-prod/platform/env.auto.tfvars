# Values for this environment that the shared stack code in
# infra/stacks/platform declares with no default.
project_id                = "prod-fin-observatory"
region                    = "europe-west1"
namespace                 = "dfo-prod"
allowed_consumer_projects = ["prod-fin-observatory"]

# Two dedicated vCPUs and 7.5 GB, zonal. Dev's one vCPU stayed under 15% CPU
# in 99% of minutes over 74 days of internal use, so the second vCPU is
# headroom for public traffic.
tier = "db-custom-2-7680"

# Room above the worst-case budget of about 145 for raising service instance
# caps without another restart. Cloud SQL's own default at 7.5 GB is 400.
max_connections = 300
