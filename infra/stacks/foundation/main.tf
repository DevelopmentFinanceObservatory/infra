terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.11.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.11.0"
    }
  }
}

# user_project_override and billing_project send every call with
# project_id as the quota project. google_billing_budget requires it: the
# Cloud Billing Budget API rejects a call with no quota project.
provider "google" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}

# Only google_project_service_identity below needs the beta provider.
provider "google-beta" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}

data "google_project" "this" {}

resource "google_project_service" "apis" {
  for_each = toset([
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "drive.googleapis.com",
    "docs.googleapis.com",
    "sheets.googleapis.com",
    "workflows.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

# The Workflows service agent. Google creates a service's agent some time
# after the API is first enabled, and dcp's stack module grants this agent a
# role and creates a workflow in the same apply that enables Workflows, so on
# a new project that apply fails with "Workflows service agent does not
# exist". Foundation applies before dcp, so generating the agent here means it
# exists by then. On a project that already has the agent, this returns it.
resource "google_project_service_identity" "workflows" {
  provider = google-beta
  service  = "workflows.googleapis.com"

  depends_on = [google_project_service.apis]
}

# Shared Artifact Registry repo. The dfo-dcp, dfo-ai, and dfo-apis service
# images all push here, so it belongs to no single stack. Writers push
# git-SHA tags, but review requirements differ between them. dfo-website
# pushes to its own repo below rather than here. A consumer that needs the
# guarantee pins its image to a digest rather than a tag, which keeps it
# resolving to the exact image it pinned even after a same-tag rebuild.
# Enforcing immutable tags at the repository would cost more than it buys.
# Immutable tags also block deletion, so a rebuild that produces a
# different digest for a SHA already pushed has no way back except a new
# commit.
resource "google_artifact_registry_repository" "datacommons" {
  location      = var.region
  repository_id = "datacommons"
  format        = "DOCKER"
  description   = "DFO Data Commons service images"

  # A keep rule always wins over a delete rule that matches the same
  # version, regardless of the order the rules appear below. keep_count
  # shields the most recent versions from every delete rule. An older
  # version still survives if no delete rule matches it. keep_count is
  # what a Cloud Run rollback depends on. A rollback to a revision whose
  # image this policy has already deleted fails.
  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-stale"
    action = "DELETE"
    condition {
      older_than = "2592000s"
      tag_state  = "TAGGED"
    }
  }

  depends_on = [google_project_service.apis]
}

# dcp's own build-cache repo, separate from `datacommons` so its writer grant
# below can be scoped to dfo-dcp-deployer alone. AR IAM has no granularity
# below the repository, and the buildcache tag moves on every push, so
# sharing it with ai/apis would let either overwrite dcp's cache manifests.
resource "google_artifact_registry_repository" "dcp_build_cache" {
  location      = var.region
  repository_id = "dfo-dcp-build-cache"
  format        = "DOCKER"
  description   = "BuildKit cache manifests for dcp, writable by dfo-dcp-deployer only"

  cleanup_policy_dry_run = false

  # The buildcache tag moves to the newest manifest on every push, so the
  # manifests this cache can reclaim sit untagged. The condition matches
  # tag_state ANY to reach them. TAGGED would miss them.
  cleanup_policies {
    id     = "delete-stale"
    action = "DELETE"
    condition {
      older_than = "1209600s"
      tag_state  = "ANY"
    }
  }

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 2
    }
  }

  depends_on = [google_project_service.apis]
}

# dfo-website's own repo, separate from `datacommons` so its writer grant
# below can be scoped to the website deployer alone. AR IAM has no
# granularity below the repository, and dev's `dev` branch deploys on
# every push with no review gate, so sharing it with dcp/ai/apis would let
# that push reach their images too.
resource "google_artifact_registry_repository" "website" {
  location      = var.region
  repository_id = var.website_artifact_repository_id
  format        = "DOCKER"
  description   = "dfo-website ${var.github_repositories["website"].deploy_environment} service images, writable by ${var.website_deployer_account_id} only"

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-stale"
    action = "DELETE"
    condition {
      older_than = "2592000s"
      tag_state  = "TAGGED"
    }
  }

  depends_on = [google_project_service.apis]
}

# Single pool for GitHub Actions across every DFO repo. Providers are scoped
# per repo below via each deployer SA's WIF binding, not per pool.
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = var.pool_id
  display_name              = "GitHub Actions"
  description               = "WIF pool for GitHub Actions across DFO repos"
  disabled                  = false

  depends_on = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "GitHub OIDC"

  # repo_environment, repo_ref and repo_env_ref exist so a deployer binding
  # can name one GitHub Environment, one git ref, or both together, without
  # matching the raw `sub` claim.
  # GitHub does not emit one subject shape: dfo-infra still gets the legacy
  # `repo:<owner>/<repo>` prefix while dfo-ai and dfo-apis already get the
  # immutable `repo:<owner>@<owner_id>/<repo>@<repo_id>` form, with all three
  # reporting `use_default: true` — the shape is GitHub's to change, per
  # repository, without notice. A `principal://.../subject/...` binding
  # therefore encodes a value this project neither controls nor can observe
  # drifting, and the failure is a hard 403 at the deploy's auth step.
  #
  # repo_env_ref pins both at once, which is what an image deployer needs.
  # A GitHub Environment's deployment branch policy is the only thing
  # deciding which refs may deploy under it, that policy lives in the service
  # repository rather than here, and widening it fails open: more branches
  # mint the identity, Terraform plans clean, CI stays green. Requiring the
  # ref to match as well moves the boundary into GCP IAM, where this repo
  # owns it, and turns policy drift into a denied exchange on the offending
  # run rather than a silent widening.
  #
  # All three compose from `repository_id` rather than `repository` for the same
  # reason the attribute condition below gates on ids. A repository rename or
  # transfer changes the name and preserves the id, so a name-composed
  # binding would keep exchanging tokens and stop matching anything, with
  # Terraform planning clean throughout because nothing in this repo changed
  # — the identical silent failure these attributes exist to end. Names stay
  # mapped above for legibility; they do not decide authorization.
  #
  # All three guard on the claims being present rather than referencing them
  # bare.
  # This mapping is evaluated for every token the pool exchanges, including
  # jobs that declare no `environment:` and so carry no `environment` claim,
  # such as the apis repository's search eval jobs. An unguarded
  # concatenation would fail those exchanges. The guard uses `in` and a
  # ternary, both documented for the restricted CEL subset attribute
  # mappings accept, unlike the `has()` macro. repo_env_ref nests two of
  # those guards rather than joining them with `&&`, which is documented for
  # attribute conditions but not for mappings, and every construct here has
  # already been exercised by a live exchange on this pool.
  #
  # The absent-claim fallback is the bare repository id, not an empty string
  # or a sentinel: an id is digits only, and every binding composed from
  # these is `<repository_id>:<value>`, so the fallback cannot collide with a
  # real binding even if an environment were named to imitate one.
  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.repository"          = "assertion.repository"
    "attribute.repository_owner"    = "assertion.repository_owner"
    "attribute.repository_id"       = "assertion.repository_id"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
    "attribute.repo_environment"    = "'environment' in assertion ? assertion.repository_id + ':' + assertion.environment : assertion.repository_id"
    "attribute.repo_ref"            = "'ref' in assertion ? assertion.repository_id + ':' + assertion.ref : assertion.repository_id"
    "attribute.repo_env_ref"        = "'environment' in assertion ? ('ref' in assertion ? assertion.repository_id + ':' + assertion.environment + ':' + assertion.ref : assertion.repository_id) : assertion.repository_id"
  }
  # Required: the GitHub OIDC issuer rejects a provider with no attribute
  # condition. Gated on the immutable org id and repository ids, not their
  # names — GitHub org and repository names can be released and
  # re-registered, so a name-based condition trusts whoever holds the name
  # when a token is minted, not the account that held it when this
  # condition was written.
  # `attribute.repository` stays mapped above because each deployer SA's
  # own WIF binding (infra/modules/github-deployer) keys its per-repo scoping
  # off it; `attribute.repository_owner` stays mapped for visibility only,
  # now that org-level scoping runs on `repository_owner_id` instead. The
  # repository id is gated here directly, rather than left for per-repo
  # bindings to enforce on their own, so token exchange itself — not just
  # impersonation afterward — is limited to the repositories that use this
  # pool. A `for` over a map visits its keys in sorted order, so the
  # generated list, and therefore this condition string, is stable across
  # plans regardless of edits elsewhere in the map.
  #
  # This is pool-level config shared by every deployer identity below
  # (planner, applier, ai_deployer, apis_deployer, dcp_deployer,
  # website_deployer, docs_sync, and site_qa_deployer where the environment
  # lists the site QA repository). Get it wrong and every
  # GitHub Actions run loses GCP access, including the applier that would
  # normally fix it forward — recovery then means a human running Terraform
  # locally with owner credentials.
  #
  # The condition holds one clause per owner, each pairing that owner's id
  # with that owner's repository ids, so a repository id is admitted only
  # under the owner that lists it. With a single owner, as in prod, the
  # condition is that one clause unwrapped.
  attribute_condition = length(local.wif_owner_clauses) == 1 ? local.wif_owner_clauses[0] : join(" || ", [for clause in local.wif_owner_clauses : "(${clause})"])

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Each deployer's `repository` argument below is derived from the same
# var.github_repositories map that gates the provider's attribute
# condition above, so the two can't drift: a role missing from the map
# fails this lookup at plan time — a hard error — rather than deploying a
# binding whose token the provider condition then rejects at CI time.
# Adding another deployer means adding its entry to var.github_repositories
# and referencing it here by role; nothing else needs to change.
locals {
  repository_owner    = { for role, repo in var.github_repositories : role => repo.owner != null ? repo.owner : { name = var.github_owner, id = var.github_owner_id } }
  deployer_repository = { for role, repo in var.github_repositories : role => "${local.repository_owner[role].name}/${repo.name}" }

  # Repository ids grouped by owner id. A `for` over a map visits roles in
  # sorted order, so each owner's list, and the condition built from it, is
  # stable across plans.
  owner_repository_ids = { for role, repo in var.github_repositories : local.repository_owner[role].id => repo.id... }
  wif_owner_clauses    = [for owner_id, ids in local.owner_repository_ids : "assertion.repository_owner_id == '${owner_id}' && assertion.repository_id in ${jsonencode(ids)}"]
}

# Project-level roles for the applier SA, one entry per resource type the
# dcp stack (and this stack) declare, plus the reads its `data` sources need.
# Keep this list in sync with what `../dcp` actually provisions — see
# infra/modules/README.md for the module inventory.
#
# The applier deliberately has no `roles/viewer`, so unlike the planner it does
# not get resource reads for free: every `data` source the stacks resolve at
# apply time needs its permission listed here explicitly.
locals {
  applier_project_roles = [
    "roles/run.admin",                            # Cloud Run services + ingestion jobs (dcp, ai, website)
    "roles/iam.serviceAccountAdmin",              # create/manage service accounts (all stacks)
    "roles/iam.serviceAccountUser",               # actAs runtime SAs when deploying Run/Workflows
    "roles/resourcemanager.projectIamAdmin",      # project-level IAM bindings (foundation, dcp)
    "roles/iam.roleAdmin",                        # custom project roles — projectIamAdmin binds them but cannot create or read them (apis)
    "roles/iam.workloadIdentityPoolAdmin",        # WIF pool/provider (foundation)
    "roles/artifactregistry.admin",               # Artifact Registry repo (foundation, dcp)
    "roles/secretmanager.admin",                  # secrets + versions + IAM (dcp, ai, website)
    "roles/storage.admin",                        # GCS buckets + terraform state (dcp bucket, state)
    "roles/spanner.admin",                        # Spanner instance + database (dcp)
    "roles/cloudsql.admin",                       # Cloud SQL instance + databases + users (website datasets instance, dcp datasets db)
    "roles/workflows.admin",                      # ingestion Cloud Workflow (dcp)
    "roles/redis.admin",                          # Memorystore Redis — only when enable_redis=true (dcp)
    "roles/vpcaccess.admin",                      # VPC Access Connector — only when enable_redis=true (dcp)
    "roles/serviceusage.serviceUsageAdmin",       # enable project APIs (all stacks)
    "roles/serviceusage.apiKeysAdmin",            # google_apikeys_key: Maps API key (dcp auth module)
    "roles/bigquery.connectionAdmin",             # google_bigquery_connection (dcp spanner federation)
    "roles/bigquery.resourceAdmin",               # google_bigquery_reservation + assignment (dcp)
    "roles/bigquery.jobUser",                     # data.google_bigquery_default_service_account (dcp spanner federation)
    "roles/bigquery.dataOwner",                   # google_bigquery_dataset (pipelines)
    "roles/compute.networkViewer",                # data.google_compute_network.default (dcp)
    "roles/compute.networkAdmin",                 # consumer PSC network VPC + subnetwork + address + forwarding rule (website, dcp)
    "roles/compute.loadBalancerAdmin",            # serverless NEG create/delete, which networkAdmin only reads (edge)
    "roles/compute.securityAdmin",                # Cloud Armor security policy create/update/delete (edge)
    "roles/certificatemanager.editor",            # DNS authorization, managed certificate, certificate map + entries (edge)
    "roles/dns.admin",                            # consumer PSC DNS zone + record set (apis, website)
    "roles/cloudtasks.queueAdmin",                # google_cloud_tasks_queue (apis datasets worker dispatch)
    "roles/cloudscheduler.admin",                 # google_cloud_scheduler_job (apis coverage tick)
    "roles/logging.configWriter",                 # google_logging_metric (apis coverage staleness alert)
    "roles/monitoring.alertPolicyEditor",         # google_monitoring_alert_policy (apis coverage staleness alert)
    "roles/monitoring.notificationChannelEditor", # google_monitoring_notification_channel (foundation Gemini budget)
  ]
}

# Stacks this repository owns state for, i.e. the state prefixes the planner
# is allowed to read the contents of. It lists the stacks of every
# environment, so it is a superset of what either one plans. plan.yml and
# plan-prod.yml derive their matrices from scripts/terraform-stacks.sh;
# this list is kept in sync with the stack directories by hand.
locals {
  state_bucket_stacks = ["foundation", "ai", "apis", "website", "dcp", "platform", "pipelines", "edge", "telemetry"]
}

# Read-only plan on pull requests: can see everything but change nothing.
# var.planner_wif_ref and var.planner_wif_environment set its WIF binding per
# environment. In prod a planner job runs PR code on the main ref, so the
# binding also names the `plan` environment, which the applier's never does.
module "planner" {
  source = "../../modules/github-deployer"

  project_id     = var.project_id
  project_number = data.google_project.this.number
  pool_id        = google_iam_workload_identity_pool.github.workload_identity_pool_id
  repository     = local.deployer_repository["infra"]
  repository_id  = var.github_repositories["infra"].id

  account_id   = "dfo-infra-planner"
  display_name = "dfo-infra Terraform planner (CI)"
  # roles/viewer reads resource state; iam.securityReviewer adds the
  # *.getIamPolicy reads a plan needs to refresh IAM bindings (notably
  # storage.buckets.getIamPolicy for the state-bucket member below, which
  # roles/viewer does not grant). serviceUsageConsumer grants
  # serviceusage.services.use, which the dcp stack's storage-bucket read
  # needs under user-project-override (viewer omits it). All read-only.
  project_roles     = ["roles/viewer", "roles/iam.securityReviewer", "roles/serviceusage.serviceUsageConsumer"]
  state_bucket      = var.state_bucket
  state_bucket_role = "roles/storage.objectViewer"
  # Restricted to this repo's own state prefixes rather than the whole
  # bucket — see the module variable for why the object-scoped condition
  # this builds is unioned with an unconditioned allow on the Bucket
  # resource itself.
  state_bucket_object_prefixes = [for stack in local.state_bucket_stacks : "terraform/state/${var.namespace}/${stack}/"]
  wif_environment              = var.planner_wif_environment
  wif_ref                      = var.planner_wif_ref

  # The SA itself needs iam.googleapis.com; on a fresh project nothing else
  # orders it after API enablement (the pool_id input only chains the WIF
  # binding, not the account).
  depends_on = [google_project_service.apis]
}

# The read-only planner (roles/viewer) cannot read secret *versions*, so grant
# it resource-scoped access to just the hand-seeded Data Commons API key secret
# that the dcp stack sources via a data source (see infra/stacks/dcp/dfo.tf).
# The applier needs no grant — it already holds project-wide
# roles/secretmanager.admin. This secret is created by hand (owner), not by
# Terraform, so we reference it by its fully-qualified name.
resource "google_secret_manager_secret_iam_member" "dc_key_planner" {
  secret_id = "projects/${var.project_id}/secrets/dc-api-key"
  role      = "roles/secretmanager.secretAccessor"
  member    = module.planner.member
}

# The same grant on each stack's hand-made principals secret, which holds the
# addresses that stack grants or notifies (the telemetry stack reads
# <namespace>-telemetry-principals in its main.tf). The planner reads it to
# plan that stack. scripts/bootstrap-principals.sh makes the same grant when
# it creates the secret, since the stack's first plan can run before this
# one applies.
locals {
  principals_secrets = [for stack in var.principals_secret_stacks : "${var.namespace}-${stack}-principals"]
}

resource "google_secret_manager_secret_iam_member" "principals_planner" {
  for_each = toset(local.principals_secrets)

  secret_id = "projects/${var.project_id}/secrets/${each.key}"
  role      = "roles/secretmanager.secretAccessor"
  member    = module.planner.member
}

# This stack's own principals: the applier impersonators and the ingestion
# operators, read from a hand-made secret so no address sits in the repository
# or in plan output. It holds
#   {"applier_impersonators": {"<label>": "<member>"}, "ingestion_operators": {"<label>": "<member>"}}
# with either object empty, and scripts/bootstrap-principals.sh writes it.
# Resources are keyed by label, since Terraform rejects sensitive for_each keys
# and an address in a key would print in every plan, so a label may hold only
# lower-case letters, digits, hyphens and underscores.
data "google_secret_manager_secret_version" "principals" {
  secret = "projects/${var.project_id}/secrets/${var.namespace}-foundation-principals"

  lifecycle {
    postcondition {
      condition = try(alltrue(concat(
        [for label in keys(jsondecode(self.secret_data).applier_impersonators) : can(regex("^[a-z0-9_-]+$", label))],
        [for label in keys(jsondecode(self.secret_data).ingestion_operators) : can(regex("^[a-z0-9_-]+$", label))],
      )), false)
      error_message = "The foundation principals secret must be a JSON object with applier_impersonators and ingestion_operators objects, each keyed by labels of lower-case letters, digits, hyphens and underscores."
    }
    postcondition {
      condition = try(alltrue([
        for m in concat(
          values(jsondecode(self.secret_data).applier_impersonators),
          values(jsondecode(self.secret_data).ingestion_operators),
        ) : can(regex("^(group|user|serviceAccount|domain):[^:]+$", m))
      ]), false)
      error_message = "Each value in the foundation principals secret must be group:, user:, serviceAccount: or domain: followed by an address."
    }
  }
}

locals {
  principals = jsondecode(data.google_secret_manager_secret_version.principals.secret_data)
}

# Applies this environment's stacks on a push to its branch. No separate
# state_bucket grant: roles/storage.admin above already covers the state
# bucket. var.applier_wif_ref pins the binding to that branch and
# var.applier_wif_environment to the environment apply-stack.yml declares
# for it.
module "applier" {
  source = "../../modules/github-deployer"

  project_id     = var.project_id
  project_number = data.google_project.this.number
  pool_id        = google_iam_workload_identity_pool.github.workload_identity_pool_id
  repository     = local.deployer_repository["infra"]
  repository_id  = var.github_repositories["infra"].id

  account_id      = "dfo-infra-applier"
  display_name    = "dfo-infra Terraform applier (CI)"
  project_roles   = local.applier_project_roles
  wif_environment = var.applier_wif_environment
  wif_ref         = var.applier_wif_ref

  depends_on = [google_project_service.apis]
}

# Scheduled queries (the telemetry stack's logs_daily) are Data Transfer
# Service configs. The only predefined role that creates them is
# roles/bigquery.admin, which also carries every table's data, so the applier
# gets the two transfer permissions alone.
resource "google_project_iam_custom_role" "applier_transfer_configs" {
  project     = var.project_id
  role_id     = "dfoInfraApplierTransferConfigs"
  title       = "dfo-infra applier: BigQuery transfer configs"
  description = "bigquery.transfers.get and bigquery.transfers.update, to create, change and delete scheduled queries."
  permissions = [
    "bigquery.transfers.get",
    "bigquery.transfers.update",
  ]
}

resource "google_project_iam_member" "applier_transfer_configs" {
  project = var.project_id
  role    = google_project_iam_custom_role.applier_transfer_configs.id
  member  = module.applier.member
}

# The applier holds the only Postgres login on the shared Cloud SQL instance,
# and that instance is PSC-only with no route from a laptop, so reading
# database state (a pg_database ACL, a role's grants, what a provision script
# actually did) means calling the Cloud SQL Data API as this account. Minting
# an access token for it is what makes those reads possible.
#
# roles/owner does not carry iam.serviceAccounts.getAccessToken, so a project
# owner still needs this binding to impersonate. It grants reach over
# everything in applier_project_roles above, which is close to the whole
# project, so it belongs only to people who can already grant themselves
# those roles directly.
#
# Calls made with a minted token log under the applier's own principalEmail,
# the same identity every CI apply writes, so a human read-back blends into
# automation at a glance. The original caller survives in
# authenticationInfo.serviceAccountDelegationInfo. Anyone auditing this
# account's activity has to read that field to tell a person from a pipeline.
resource "google_service_account_iam_member" "applier_impersonator" {
  for_each = toset(nonsensitive(keys(local.principals.applier_impersonators)))

  service_account_id = module.applier.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = local.principals.applier_impersonators[each.key]
}

# The resource above and the five ingestion operator resources below were once
# keyed by member string. Their old state entries are forgotten, so the live
# bindings stay, and the label-keyed resources re-create the same bindings,
# which IAM accepts as no change.
removed {
  from = google_service_account_iam_member.applier_impersonators
  lifecycle {
    destroy = false
  }
}

# The foundation creates dfo-ai's deployer identity and grants its Artifact
# Registry access. The ai stack grants Cloud Run access on the service itself.
module "ai_deployer" {
  source = "../../modules/github-deployer"

  project_id     = var.project_id
  project_number = data.google_project.this.number
  pool_id        = google_iam_workload_identity_pool.github.workload_identity_pool_id
  repository     = local.deployer_repository["ai"]
  repository_id  = var.github_repositories["ai"].id

  account_id      = "dfo-ai-deployer"
  display_name    = "dfo-ai image deployer (CI)"
  project_roles   = []
  wif_environment = var.github_repositories["ai"].deploy_environment
  wif_ref         = "refs/heads/${var.github_repositories["ai"].deploy_branch}"
  artifact_registry_repositories = [{
    repository_id = google_artifact_registry_repository.datacommons.repository_id
    location      = google_artifact_registry_repository.datacommons.location
    role          = "roles/artifactregistry.writer"
  }]

  depends_on = [google_project_service.apis]
}

# Image-only Cloud Run updates from the dfo-dcp repo. The ai and apis stacks
# grant their deployers Cloud Run access on the exact resources they update.
# dcp's Cloud Run service is created inside the pinned upstream module
# (git::https://github.com/datacommonsorg/datacommons.git//infra/dcp/modules/stack),
# which leaves nothing here to attach `lifecycle.ignore_changes` to, so only
# a real `terraform apply` can change dcp's image. dfo-dcp's CI only pushes
# to Artifact Registry and opens a pin PR; dfo-infra's applier runs the
# apply. This SA needs nothing beyond the AR pushes (image, buildcache): no
# run.developer, no actAs.
module "dcp_deployer" {
  source = "../../modules/github-deployer"

  project_id     = var.project_id
  project_number = data.google_project.this.number
  pool_id        = google_iam_workload_identity_pool.github.workload_identity_pool_id
  repository     = local.deployer_repository["dcp"]
  repository_id  = var.github_repositories["dcp"].id

  account_id      = "dfo-dcp-deployer"
  display_name    = "dfo-dcp image builder (CI)"
  project_roles   = []
  wif_environment = var.github_repositories["dcp"].deploy_environment
  wif_ref         = "refs/heads/${var.github_repositories["dcp"].deploy_branch}"
  artifact_registry_repositories = [
    {
      repository_id = google_artifact_registry_repository.datacommons.repository_id
      location      = google_artifact_registry_repository.datacommons.location
      role          = "roles/artifactregistry.writer"
    },
    {
      repository_id = google_artifact_registry_repository.dcp_build_cache.repository_id
      location      = google_artifact_registry_repository.dcp_build_cache.location
      role          = "roles/artifactregistry.writer"
    },
  ]

  depends_on = [google_project_service.apis]
}

# The foundation creates dfo-apis's deployer identity and grants its Artifact
# Registry access. The apis stack grants Cloud Run access on its service and
# migration Jobs, plus actAs on their runtime service accounts.
module "apis_deployer" {
  source = "../../modules/github-deployer"

  project_id     = var.project_id
  project_number = data.google_project.this.number
  pool_id        = google_iam_workload_identity_pool.github.workload_identity_pool_id
  repository     = local.deployer_repository["apis"]
  repository_id  = var.github_repositories["apis"].id

  account_id      = "dfo-apis-deployer"
  display_name    = "dfo-apis image deployer (CI)"
  project_roles   = []
  wif_environment = var.github_repositories["apis"].deploy_environment
  wif_ref         = "refs/heads/${var.github_repositories["apis"].deploy_branch}"
  artifact_registry_repositories = [{
    repository_id = google_artifact_registry_repository.datacommons.repository_id
    location      = google_artifact_registry_repository.datacommons.location
    role          = "roles/artifactregistry.writer"
  }]

  depends_on = [google_project_service.apis]
}

# Image-only Cloud Run updates from dfo-website. Dev's `dev`
# environment auto-deploys on every push to its branch with no review
# requirement. Bounded to its own Cloud Run service and migrate job (granted
# in the website stack) and its own Artifact Registry repo, keeping that
# push from reaching anything else.
module "website_deployer" {
  source = "../../modules/github-deployer"

  project_id     = var.project_id
  project_number = data.google_project.this.number
  pool_id        = google_iam_workload_identity_pool.github.workload_identity_pool_id
  repository     = local.deployer_repository["website"]
  repository_id  = var.github_repositories["website"].id

  account_id      = var.website_deployer_account_id
  display_name    = "dfo-website ${var.github_repositories["website"].deploy_environment} image deployer (CI)"
  project_roles   = []
  wif_environment = var.github_repositories["website"].deploy_environment
  wif_ref         = "refs/heads/${var.github_repositories["website"].deploy_branch}"
  artifact_registry_repositories = [{
    repository_id = google_artifact_registry_repository.website.repository_id
    location      = google_artifact_registry_repository.website.location
    role          = "roles/artifactregistry.writer"
  }]

  depends_on = [google_project_service.apis]
}

moved {
  from = google_artifact_registry_repository.website_staging
  to   = google_artifact_registry_repository.website
}

moved {
  from = module.website_staging_deployer
  to   = module.website_deployer
}

# dfo-docs' Google Docs sync. The service account holds no project role and
# no Terraform-managed resource grant: it reaches Drive, Docs, and Sheets
# only as a member of the ONE Data shared drive, a membership granted outside
# Terraform. Its WIF binding is pinned to the docs entry's deploy_branch and,
# when set, its deploy_environment. Dev pins docsync.yml's runs from dev in
# the docsync environment.
module "docs_sync" {
  source = "../../modules/github-deployer"

  project_id     = var.project_id
  project_number = data.google_project.this.number
  pool_id        = google_iam_workload_identity_pool.github.workload_identity_pool_id
  repository     = local.deployer_repository["docs"]
  repository_id  = var.github_repositories["docs"].id

  account_id      = "dfo-docs-sync"
  display_name    = "dfo-docs Google Docs sync (CI)"
  description     = "Reads and writes the ONE Data shared drive for dfo-docs' Google Docs sync; holds no project roles"
  project_roles   = []
  wif_environment = var.github_repositories["docs"].deploy_environment
  wif_ref         = "refs/heads/${var.github_repositories["docs"].deploy_branch}"

  depends_on = [google_project_service.apis]
}

# The site QA repository's Firebase deploy: its Hosting site and the rules
# and indexes of the site-qa Firestore database, on every push to main. The
# tracker exists only in dev, so the account exists only in an environment
# whose github_repositories lists site_qa, which stays private under its
# original owner. Its WIF binding is pinned to refs/heads/main.
module "site_qa_deployer" {
  count  = contains(keys(var.github_repositories), "site_qa") ? 1 : 0
  source = "../../modules/github-deployer"

  project_id     = var.project_id
  project_number = data.google_project.this.number
  pool_id        = google_iam_workload_identity_pool.github.workload_identity_pool_id
  repository     = local.deployer_repository["site_qa"]
  repository_id  = var.github_repositories["site_qa"].id

  account_id   = "dfo-site-qa-deployer"
  display_name = "dfo-site-qa Firebase deployer (CI)"
  project_roles = [
    "roles/firebasehosting.admin",             # upload and release Hosting versions
    "roles/firebaserules.admin",               # release firestore.rules
    "roles/datastore.indexAdmin",              # deploy firestore.indexes.json
    "roles/serviceusage.serviceUsageConsumer", # firebase-tools checks the Firestore API is enabled
  ]
  wif_ref = "refs/heads/main"

  depends_on = [google_project_service.apis]
}

# Grants for the people who run Dagster ingestion into this environment's
# Data Commons. Dagster starts the dcp ingestion workflow as the workflow's
# own service account, stages import bundles in the artifacts bucket, and
# reads the Spanner database to check what landed. All four resources
# belong to the dcp stack, which applies after this one, so their names
# arrive as variables and the secret's ingestion_operators object stays empty
# until dcp exists. Each resource is keyed by the operator's label.
locals {
  ingestion_operators = toset(nonsensitive(keys(local.principals.ingestion_operators)))
}

resource "google_service_account_iam_member" "ingestion_workflow_token_creator" {
  for_each = local.ingestion_operators

  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.ingestion_workflow_service_account_email}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = local.principals.ingestion_operators[each.key]

  lifecycle {
    precondition {
      condition     = var.ingestion_workflow_service_account_email != null
      error_message = "The foundation principals secret lists ingestion_operators, so ingestion_workflow_service_account_email must be too."
    }
  }
}

resource "google_storage_bucket_iam_member" "ingestion_artifacts_writer" {
  for_each = local.ingestion_operators

  bucket = var.ingestion_artifacts_bucket_name
  role   = "roles/storage.objectUser"
  member = local.principals.ingestion_operators[each.key]

  lifecycle {
    precondition {
      condition     = var.ingestion_artifacts_bucket_name != null
      error_message = "The foundation principals secret lists ingestion_operators, so ingestion_artifacts_bucket_name must be too."
    }
  }
}

# Cloud Workflows has no per-workflow IAM resource in the provider, so the
# invoker grant is project-wide. The ingestion workflow is the only workflow
# in the project.
resource "google_project_iam_member" "ingestion_workflow_invoker" {
  for_each = local.ingestion_operators

  project = var.project_id
  role    = "roles/workflows.invoker"
  member  = local.principals.ingestion_operators[each.key]
}

# Read access to follow a run: the workflow and its executions, the bucket
# list the console needs, the logs the workflow and its prep job write, the
# prep job's executions, the Dataflow jobs the workflow launches, the
# project's metrics, and the Spanner instance and database in the console.
# serviceUsageConsumer lets an operator's gcloud and client libraries bill
# their API calls to this project. The writes stay as above, on the
# artifacts bucket's objects and on starting the workflow.
locals {
  ingestion_operator_viewer_roles = [
    "roles/workflows.viewer",
    "roles/storage.bucketViewer",
    "roles/logging.viewer",
    "roles/run.viewer",
    "roles/spanner.viewer",
    "roles/dataflow.viewer",
    "roles/monitoring.viewer",
    "roles/serviceusage.serviceUsageConsumer",
  ]
}

resource "google_project_iam_member" "ingestion_viewer" {
  for_each = {
    for pair in setproduct(local.ingestion_operators, local.ingestion_operator_viewer_roles) :
    "${pair[0]} ${pair[1]}" => { label = pair[0], role = pair[1] }
  }

  project = var.project_id
  role    = each.value.role
  member  = local.principals.ingestion_operators[each.value.label]
}

resource "google_spanner_database_iam_member" "ingestion_database_reader" {
  for_each = local.ingestion_operators

  instance = var.ingestion_spanner_instance_id
  database = var.ingestion_spanner_database_id
  role     = "roles/spanner.databaseReader"
  member   = local.principals.ingestion_operators[each.key]

  lifecycle {
    precondition {
      condition     = var.ingestion_spanner_instance_id != null && var.ingestion_spanner_database_id != null
      error_message = "The foundation principals secret lists ingestion_operators, so ingestion_spanner_instance_id and ingestion_spanner_database_id must be too."
    }
  }
}

removed {
  from = google_service_account_iam_member.ingestion_operator_workflow_token_creator
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_storage_bucket_iam_member.ingestion_operator_artifacts_writer
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_project_iam_member.ingestion_operator_workflow_invoker
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_project_iam_member.ingestion_operator_viewer
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_spanner_database_iam_member.ingestion_operator_database_reader
  lifecycle {
    destroy = false
  }
}
