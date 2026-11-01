variable "project_id" {
  description = "GCP project this environment deploys into."
  type        = string
}

variable "region" {
  description = "Default GCP region for regional resources."
  type        = string
}

variable "namespace" {
  description = "Prefix for this environment's resource names, such as dfo-dev."
  type        = string
}

variable "github_owner" {
  description = "GitHub org/user that owns the repos allowed to assume WIF identities from this pool."
  type        = string
}

variable "github_owner_id" {
  description = "Immutable numeric id of var.github_owner, gating the WIF attribute condition instead of the org name. Org names can be released and re-registered by someone else, but the id cannot — it must be read from the GitHub API (GET /orgs/{org} -> id), not guessed or derived from the name. A github_repositories entry under another owner carries that owner's name and id in its own owner field."
  type        = string
}

variable "github_repositories" {
  description = "The GitHub repositories this environment trusts, keyed by role (infra, ai, apis, dcp, website, docs, and optionally site_qa, which only dev lists). Each entry carries the repository's name under var.github_owner, or under owner.name when the entry sets owner, and its immutable numeric id, read from the GitHub API (GET /repos/{owner}/{repo} -> id) and never guessed: a name can be released and re-registered by someone else, an id cannot. The ids gate the WIF attribute condition alongside their owner's id (owner.id, or github_owner_id when owner is unset): the condition admits each owner's own listed repositories and nothing else, and each binding's repository comes from the same entry. Dev lists site_qa, the site QA repository, under its original owner (6450343). The four image deployers (ai, apis, dcp, website) also carry deploy_environment and deploy_branch, the GitHub Environment and git branch their WIF binding is pinned to, so only a run on that branch under that Environment can mint the identity. docs carries deploy_branch, and optionally deploy_environment, for the dfo-docs-sync binding: dev sets docsync on dev, where docsync.yml runs. Those two are kept in step with scripts/deploy-targets.sh, which writes and audits the matching deployment branch policy; the two disagreeing breaks that repository's next deploy at the auth step rather than widening anything. An entry only admits its repository's tokens to the WIF provider's attribute condition. A deployer exists only for the roles named above: ai, apis, dcp, website, docs, infra and site_qa. Any other entry, such as dev's sdk, creates no identity. A stack that needs one binds it to the repository's id."
  type = map(object({
    name = string
    id   = string
    owner = optional(object({
      name = string
      id   = string
    }))
    deploy_environment = optional(string)
    deploy_branch      = optional(string)
  }))

  validation {
    condition     = alltrue([for role in ["infra", "ai", "apis", "dcp", "website", "docs"] : contains(keys(var.github_repositories), role)])
    error_message = "github_repositories must hold the roles infra, ai, apis, dcp, website, and docs."
  }

  validation {
    condition     = alltrue([for role in ["ai", "apis", "dcp", "website"] : try(var.github_repositories[role].deploy_environment != null && var.github_repositories[role].deploy_branch != null, false)])
    error_message = "The ai, apis, dcp, and website entries of github_repositories must set deploy_environment and deploy_branch."
  }

  validation {
    condition     = try(var.github_repositories["docs"].deploy_branch != null, false)
    error_message = "The docs entry of github_repositories must set deploy_branch, the branch the dfo-docs-sync binding is pinned to."
  }

  validation {
    condition     = alltrue([for repo in values(var.github_repositories) : can(regex("^[0-9]+$", repo.id))])
    error_message = "Every github_repositories id must be the repository's numeric GitHub id (GET /repos/{owner}/{repo} -> id)."
  }

  validation {
    condition     = alltrue([for repo in values(var.github_repositories) : repo.owner == null || can(regex("^[0-9]+$", repo.owner.id))])
    error_message = "Every github_repositories owner.id must be the owner's numeric GitHub id (GET /users/{owner} -> id)."
  }
}

variable "planner_wif_ref" {
  description = "Git ref the dfo-infra-planner WIF binding is pinned to, such as refs/heads/main, or null. With planner_wif_environment also null, the binding is repo-scoped and any workflow in the infra repository can use it. Prod sets refs/heads/main, because plan-prod.yml runs on pull_request_target, whose ref is the default branch, main. Dev sets null, because its plan.yml runs on pull_request and carries refs/pull/<n>/merge. Every environment sets it, so no new environment inherits the repo-scoped binding by omission."
  type        = string
}

variable "planner_wif_environment" {
  description = "GitHub Environment the dfo-infra-planner WIF binding also requires, or null for none. Prod sets plan, which only plan-prod.yml's plan job declares. That job runs on pull_request_target, so its token carries refs/heads/main, the applier's ref; the environment claim is what keeps it from matching the applier. Dev sets null."
  type        = string
}

variable "applier_wif_ref" {
  description = "Git ref the dfo-infra-applier WIF binding is pinned to: the branch whose pushes apply this environment. Prod sets refs/heads/main and dev refs/heads/dev, the branches apply.yml applies dfo-prod and dfo-dev from."
  type        = string

  validation {
    condition     = can(regex("^refs/heads/.+$", var.applier_wif_ref))
    error_message = "applier_wif_ref must be a branch ref, such as refs/heads/main."
  }
}

variable "applier_wif_environment" {
  description = "GitHub Environment the dfo-infra-applier WIF binding requires on applier_wif_ref, or null to bind on the ref alone. Prod sets production and dev sets dev, the environments apply-stack.yml declares for dfo-prod and dfo-dev, so a job on that ref in any other environment, or in none, cannot impersonate the applier."
  type        = string

  validation {
    condition     = !(var.applier_wif_environment == var.planner_wif_environment && var.applier_wif_ref == var.planner_wif_ref)
    error_message = "The planner and applier WIF bindings would be the same member. Give them different GitHub Environments or different refs."
  }
}

variable "website_deployer_account_id" {
  description = "Service account id of dfo-website's image deployer, at most 30 characters. The website stack looks the account up by this id."
  type        = string
}

variable "website_artifact_repository_id" {
  description = "Id of the Artifact Registry repository dfo-website's images push to, which only the website deployer may write."
  type        = string
}

variable "state_bucket" {
  description = "Terraform state GCS bucket, granted read (planner) or admin (applier) access."
  type        = string
}

variable "pool_id" {
  description = "Short workload_identity_pool_id for the shared GitHub Actions WIF pool."
  type        = string
  default     = "github-pool"
}

variable "provider_id" {
  description = "workload_identity_pool_provider_id for the GitHub OIDC provider."
  type        = string
  default     = "github"
}

variable "principals_secret_stacks" {
  description = "Stacks in this environment that read their principals from a hand-made <namespace>-<stack>-principals secret. The planner gets roles/secretmanager.secretAccessor on each, and the grant fails while the secret does not exist, so a stack is listed only in the environments that deploy it."
  type        = list(string)
  default     = []
}

variable "ingestion_workflow_service_account_email" {
  description = "Email of the dcp ingestion workflow's service account (dcp output ingestion_workflow_service_account_email). Required once the foundation principals secret's ingestion_operators object is non-empty."
  type        = string
  default     = null
}

variable "ingestion_artifacts_bucket_name" {
  description = "Name of the dcp artifacts bucket (dcp output storage_artifacts_bucket_name). Required once the foundation principals secret's ingestion_operators object is non-empty."
  type        = string
  default     = null
}

variable "ingestion_spanner_instance_id" {
  description = "Spanner instance holding the Data Commons database (dcp output spanner_instance_id). Required once the foundation principals secret's ingestion_operators object is non-empty."
  type        = string
  default     = null
}

variable "ingestion_spanner_database_id" {
  description = "Spanner database the Data Commons services read (dcp output spanner_database_id). Required once the foundation principals secret's ingestion_operators object is non-empty."
  type        = string
  default     = null
}

# The two budget variables below have no default and are set in
# budget.auto.tfvars. An empty billing_account_id or gemini_key_projects there
# switches the Gemini budgets off, so every other stack and CI's validate and
# plan keep working before anyone fills them in.
variable "billing_account_id" {
  description = "Billing account that pays for the projects holding the Gemini keys, as the bare id (`XXXXXX-XXXXXX-XXXXXX`). Look it up with `gcloud billing projects describe <project_number>`. Empty disables the Gemini budgets."
  type        = string
}

variable "gemini_key_projects" {
  description = "The projects that own this environment's Gemini API keys, keyed by caller (such as apis or ai), one budget each. project_number is the digits after `projects/` in the key name `gcloud services api-keys lookup <key string>` prints. It can belong to another project than project_id when the key came from AI Studio. budget_usd is the monthly Gemini API spend, in USD, that the budget's thresholds are percentages of. Empty disables the Gemini budgets."
  type = map(object({
    project_number = string
    budget_usd     = optional(number, 500)
  }))

  validation {
    condition     = alltrue([for p in values(var.gemini_key_projects) : can(regex("^[0-9]+$", p.project_number))])
    error_message = "Each gemini_key_projects project_number must be the project's number, digits only."
  }

  # The Budget API caps a display name at 60 characters, and budget.tf names
  # each budget "Gemini API spend: <key>". Its amount takes whole units.
  validation {
    condition     = alltrue([for k, p in var.gemini_key_projects : length(k) <= 42 && floor(p.budget_usd) == p.budget_usd])
    error_message = "Each gemini_key_projects key must be at most 42 characters, and each budget_usd a whole number of dollars."
  }
}

variable "billing_export_dataset_id" {
  description = "Id of the BigQuery dataset, in project_id, that Cloud Billing exports this environment's billing account to. Empty creates no dataset. Set it in one environment only, since one export covers every project on the account."
  type        = string
  default     = ""
}
