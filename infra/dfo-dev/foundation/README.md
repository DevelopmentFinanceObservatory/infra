# foundation — shared plumbing for the environment

Infrastructure that more than one stack (or more than one repo's CI) depends on. Nothing application-shaped lives here.

## What is here

- **Workload Identity Federation** — one pool (`github-pool`) for GitHub Actions, one OIDC provider (`github`), attribute-condition-scoped to the repository ids in `var.github_repositories`, each under its owner's id, so no CI anywhere holds a service-account key. Every repository belongs to `DevelopmentFinanceObservatory` except dev's `site_qa`, the site QA repository, which stays private under its original owner (owner id 6450343). Both gates use immutable numeric ids. GitHub org and repository names can be released and re-registered, so a name-based condition would trust whoever holds the name later instead of the account that held it when the condition was written. See "Repository allowlist" below for what the repository-id gate specifically buys.

- **Deployer service accounts** — one per CI role, smallest workable grants, each with its own WIF impersonation binding scoped to its repo and, where noted below, narrowed further to one git ref or one GitHub Environment (`infra/modules/github-deployer`):

  - `dfo-infra-planner`: read-only plan on pull requests (viewer + state bucket read). Its WIF binding follows `planner_wif_ref` and `planner_wif_environment`. Dev sets both to `null`, a repo-scoped binding, since `plan.yml` runs on pull_request and has no fixed ref to pin to. Prod sets `refs/heads/main`, the ref of its `pull_request_target` runs, and the `plan` environment, which keeps those runs off the applier's binding.

  - `dfo-infra-applier`: applies this environment's stacks on a push to its branch. WIF-pinned to the ref `applier_wif_ref` names and the GitHub Environment `applier_wif_environment` names, together. Dev sets `refs/heads/dev` and `dev`, prod `refs/heads/main` and `production`, the pairs `apply-stack.yml` declares. See "Pull-request access" below.

  - `dfo-ai-deployer`: image-only Cloud Run updates from the `ai` repo (`roles/run.developer` at project level, `roles/artifactregistry.writer` scoped to the `datacommons` Artifact Registry repo); see that repo's `deploy/README.md` for the full contract. WIF-pinned to both the `dev` GitHub Environment and `refs/heads/dev` (`wif_environment` and `wif_ref` together).

  - `dfo-apis-deployer`: image-only Cloud Run updates from the `apis` repo (`roles/run.developer` at project level, `roles/artifactregistry.writer` scoped to the `datacommons` Artifact Registry repo); see that repo's `deploy/README.md` for the full contract. WIF-pinned like `dfo-ai-deployer`.

  - `dfo-dcp-deployer`: image _build_ only for the `dcp` repo, no Cloud Run access. `dcp`'s service is created by the pinned upstream stack module in `../dcp`, which leaves nothing for `lifecycle.ignore_changes` to target, so the image-only `gcloud run services update` that `dfo-ai-deployer` and `dfo-apis-deployer` use can't work here. Only a `terraform apply` changes the image. The `dcp` repo's CI pushes to Artifact Registry and opens a pin PR against this repo instead, and `dfo-infra-applier` applies it. `project_roles = []`: this SA needs only `roles/artifactregistry.writer` on the `datacommons` repo and on `dfo-dcp-build-cache`, which it alone can write to. WIF-pinned like `dfo-ai-deployer`, though the binding covers only the Artifact Registry pushes, not the pin PR itself.

  - `dfo-website-staging-deployer`: image-only Cloud Run updates from the `website` repo's `dev` environment (no project roles; `roles/artifactregistry.writer` scoped to the `dfo-website-staging` Artifact Registry repo, and `roles/run.developer` on the service and migrate Job plus actAs on their runtime accounts, granted in the website stack); see that repo's `deploy/README.md` for the full contract. WIF-pinned like `dfo-ai-deployer`. The account and its Artifact Registry repo keep their `staging` names, since renaming either replaces it.

  - `dfo-docs-sync`: reads and writes the ONE Data shared drive for dfo-docs' Google Docs sync. `project_roles = []` and no resource grants: Drive, Docs, and Sheets access comes from the account's membership of the shared drive, granted outside Terraform. WIF-pinned to the docs entry's `deploy_environment` and `deploy_branch`: in dev, the `docsync` environment on `refs/heads/dev`, where `docsync.yml` runs. Prod sets `deploy_branch = "main"` and no environment. The stack also enables `drive.googleapis.com`, `docs.googleapis.com`, and `sheets.googleapis.com`.

  - `dfo-site-qa-deployer`: runs `firebase deploy` for the site QA repository, releasing the `dfo-site-qa` Hosting site and the rules and indexes of the `site-qa` Firestore database. Holds `roles/firebasehosting.admin`, `roles/firebaserules.admin`, `roles/datastore.indexAdmin`, and `roles/serviceusage.serviceUsageConsumer`. WIF-pinned to `refs/heads/main` (`wif_ref`). The account exists only where `github_repositories` lists `site_qa`, which only dev does.

  The `workload_identity_provider` and `ai_deployer_service_account` / `apis_deployer_service_account` / `dcp_deployer_service_account` / `website_deployer_service_account` outputs are the `WIF_PROVIDER` / `WIF_SA` values `scripts/handoff.sh` writes into the ai, apis, dcp and website repos' GitHub Environments. `scripts/handoff.sh dfo-dev docs` writes `workload_identity_provider` and `docs_sync_service_account` into docs' `docsync` environment as `GCP_WIF_PROVIDER` and `DOCSYNC_SERVICE_ACCOUNT`. The site QA repository's deploy workflow names `workload_identity_provider` and `site_qa_deployer_service_account` directly.

  Caution: WIF pools and providers soft-delete for 30 days once destroyed — don't casually destroy/recreate the pool or the `github` provider.

- **Artifact Registry repo `datacommons`** — shared Docker registry: the `dcp`, `ai`, and `apis` service images all push here, so it belongs to no single stack. Owned here, not in `../dcp`. Each image keeps its ten most recent tagged versions and drops any other tagged version older than thirty days.

- **Artifact Registry repo `dfo-dcp-build-cache`** — a second, dcp-only registry for BuildKit cache manifests. AR IAM grants writer at the repository level, so a cache repo shared with `ai`/`apis` would let their deployers overwrite dcp's cache. `dfo-dcp-deployer` is the only identity granted `roles/artifactregistry.writer` on it. Keeps the two most recent cache manifests and drops any other manifest, tagged or not, older than fourteen days.

- **Artifact Registry repo `dfo-website-staging`** — dfo-website's image repo (`var.website_artifact_repository_id`), separate from `datacommons` so its writer grant can be scoped to `dfo-website-staging-deployer` alone. Each image keeps its ten most recent tagged versions and drops any other tagged version older than thirty days.

- **Ingestion operator grants** — for each principal in `var.ingestion_operators`: token creator on the dcp ingestion workflow's service account, `roles/storage.objectUser` on the artifacts bucket, `roles/workflows.invoker` on the project (the provider has no per-workflow IAM resource), `roles/spanner.databaseReader` on the Data Commons database, and `roles/workflows.viewer`, `roles/storage.bucketViewer`, `roles/logging.viewer`, `roles/run.viewer`, `roles/spanner.viewer`, `roles/dataflow.viewer`, and `roles/monitoring.viewer` on the project, so an operator can follow a run in the console, plus `roles/serviceusage.serviceUsageConsumer` so their API calls can bill to the project. The resources belong to `../dcp`, so their names come in through the `ingestion_*` variables. Dev's list is empty, since its operators hold these roles by hand or through owner.

## Gemini spend budget

`budget.tf` creates a Cloud Billing budget on the Gemini API (billing catalog service "Gemini API", `generativelanguage.googleapis.com`) for the project that owns the dev Gemini key. It emails when spend reaches 50%, 90% and 100% of `var.gemini_budget_usd` (default 500 USD a month), and when the forecast for the month reaches 100%. Billing account admins get the default emails. Each address in `var.budget_alert_emails` gets a Cloud Monitoring email channel and the same alerts.

The budget alerts and caps nothing. Google reports billing data with a delay of hours, so the first email can arrive well after the spend it describes, and requests keep succeeding past 100%. A hard stop needs a quota on the key's project, which this stack does not set.

The budget stays off, and the stack plans as a no-op, until `budget.auto.tfvars` holds:

- `billing_account_id`: the billing account id. `gcloud billing projects describe <gemini_key_project_number>` prints it.
- `gemini_key_project_number`: the number of the project that owns the key, the digits after `projects/` in the key name `gcloud services api-keys lookup <key string>` prints. That project can differ from `project_id` when the key came from AI Studio. The budget filter takes the number, so neither the planner nor the applier needs access to that project.
- `budget_alert_emails`: the recipient list. Empty leaves billing admins as the only recipients.

One manual step before the first apply with those values set. `dfo-infra-applier` needs Billing Account Costs Manager on the billing account, and this repo does not manage billing account IAM, so a billing account admin grants it once:

```sh
gcloud billing accounts add-iam-policy-binding <billing_account_id> \
  --member=serviceAccount:dfo-infra-applier@dev-fin-observatory.iam.gserviceaccount.com \
  --role=roles/billing.costsManager
```

`dfo-infra-planner` cannot read a budget, so a pull-request plan fails on refresh once the budget exists. Grant it `roles/billing.viewer` on the billing account the same way to keep plans working:

```sh
gcloud billing accounts add-iam-policy-binding <billing_account_id> \
  --member=serviceAccount:dfo-infra-planner@dev-fin-observatory.iam.gserviceaccount.com \
  --role=roles/billing.viewer
```

The applier's project roles include `roles/monitoring.notificationChannelEditor` for the email channels, and the provider sets `user_project_override` and `billing_project` because the budget API needs a quota project.

## Billing export

`billing_export.tf` creates the BigQuery dataset that Cloud Billing exports to, in `EU` with no access blocks and no expiration. It is off until `billing_export_dataset_id` is set. One export covers every project on a billing account, so only prod sets it: `billing_export` in `prod-fin-observatory` receives the export for the billing account that pays for dev, prod and the Gemini key projects. `gcloud billing projects describe prod-fin-observatory` prints its id.

Google offers no API for the export setting, so after the first apply a billing account admin turns it on in the console under Billing → Billing export → BigQuery export. Edit the settings of both "Standard usage cost" and "Detailed usage cost", choose project `prod-fin-observatory` and dataset `billing_export`, and save. Saving adds `billing-export-bigquery@system.gserviceaccount.com` to the dataset as an owner. The dataset declares no access blocks, so Terraform leaves that grant alone.

The first export backfills from the start of the previous month, because the dataset is multi-region. The tables are `gcp_billing_export_v1_<id>` (standard) and `gcp_billing_export_resource_v1_<id>` (detailed), where `<id>` is the billing account id with underscores for hyphens, and new rows arrive a few hours after the usage. Gemini spend by project for one day:

```sql
select project.id, sku.description, round(sum(cost), 2) as cost
from `prod-fin-observatory.billing_export.gcp_billing_export_v1_*`
where service.description = "Gemini API" and date(usage_start_time) = current_date()
group by 1, 2 order by cost desc
```

## Usage logs

`log_analytics.tf` keeps three kinds of log line for SQL, in a Log Analytics bucket named `usage_logs` in `eu`:

- the website's request lines, which `logRequest` in dfo-website writes with `message: "request"`
- the website's event lines, which `track()` writes with `message: "event"`
- the apis service's resolve lines, which the `search.engine.core` logger writes as the text `resolve ` followed by a JSON object.

One sink, `usage-logs`, routes the lines from the two Cloud Run services that `usage_logs` in `env.auto.tfvars` names. The lines reach `_Default` as well, and this stack leaves `_Default` alone. A sink into a bucket in its own project needs no IAM grant. Dev keeps 30 days and prod 400. Null `usage_logs` creates nothing.

Three things cannot change once the bucket exists: the Log Analytics upgrade, the `eu` location, and the bucket id, which stays reserved for 7 days after a delete. Unsetting `usage_logs` and setting it again within a week fails apply.

The linked dataset `usage_logs` exposes the bucket to BigQuery as read-only views, in the same `EU` location as `billing_export`. Every line is in the `_AllLogs` view, with the JSON payload in the `json_payload` column. The Log Analytics page in the console queries it at no charge, and a query through BigQuery bills as a normal query. The resolve line's object parses with `SAFE.PARSE_JSON(SUBSTR(JSON_VALUE(json_payload.message), 9))`. Resolve lines by cache outcome for one day:

```sql
with resolves as (
  select safe.parse_json(substr(json_value(json_payload.message), 9)) as resolve
  from `prod-fin-observatory.usage_logs._AllLogs`
  where json_value(json_payload.logger) = "search.engine.core"
    and date(timestamp) = current_date()
)
select json_value(resolve.cache) as cache, count(*) as resolves,
  approx_quantiles(lax_float64(resolve.total_ms), 100)[offset(50)] as median_ms
from resolves
group by 1 order by resolves desc
```

Website events by name for the same day:

```sql
select json_value(json_payload.name) as name, count(*) as events
from `prod-fin-observatory.usage_logs._AllLogs`
where json_value(json_payload.message) = "event" and date(timestamp) = current_date()
group by 1 order by events desc
```

The resolve line carries `trace_id`, the same id as `diagnostics.trace_id` in the response. The website puts that id in the event's `props.traceId`, so a join on the two ties an event to the resolve behind it:

```sql
with resolves as (
  select safe.parse_json(substr(json_value(json_payload.message), 9)) as resolve
  from `prod-fin-observatory.usage_logs._AllLogs`
  where json_value(json_payload.logger) = "search.engine.core"
    and date(timestamp) = current_date()
)
select json_value(e.json_payload.name) as name, json_value(r.resolve.cache) as cache
from `prod-fin-observatory.usage_logs._AllLogs` as e
join resolves as r
  on json_value(e.json_payload.props.traceId) = json_value(r.resolve.trace_id)
where json_value(e.json_payload.message) = "event" and date(e.timestamp) = current_date()
```

## Repository allowlist

The condition holds one clause per owner: `DevelopmentFinanceObservatory`'s id with its repository ids, and in dev the site QA repository's owner id with that repository's id alone, so no other repository under that owner can exchange a token. The owner-id gate alone would confine token exchange to those owners, and a token with no matching service-account binding can do nothing there, since the only IAM grants on this pool are the eight deployer identities' bindings above. So the repository-id gate closes one specific gap left by the owner-id gate alone: a repository deleted and its name re-registered by someone else under the same owner, which would otherwise present a token whose `attribute.repository` still matches a deployer's binding.

`var.github_repositories` is also what `local.deployer_repository` derives each deployer's own `repository` argument from (see `main.tf`), so a repository is added to the map at the same time it gains a deployer, and the two can never drift apart. The map is keyed by role (`infra`, `ai`, `apis`, `dcp`, `website`, `docs`, and in dev `site_qa`), and each entry names the repository and its id, so the same code serves environments whose repositories carry other names. An entry under another owner than `github_owner` also sets `owner`, that owner's name and id.

## Pull-request access

Of the eight identities above, `dfo-infra-planner` is the one a pull-request run reaches unconditionally, by this Terraform alone. In dev its WIF binding is repo-scoped (`planner_wif_ref` and `planner_wif_environment` are null), so any workflow in `DevelopmentFinanceObservatory/infra` can impersonate it, and `plan.yml` runs on every pull request by design. It cannot mutate anything: `roles/viewer` plus the two read-only project roles alongside it grant no write API. But its read reaches further than this stack. `state_bucket` (`tf-state-dfo-dev-dev-fin-observatory`) is one GCS bucket shared by all six stacks, split only by object prefix, and the grant is a bucket-level `roles/storage.objectViewer` with no per-prefix condition, so a pull-request run can read every stack's state, not just foundation's. That includes `../dcp`'s state, which holds `random_password.datasets_migrator` in plaintext: Terraform's `sensitive` marking redacts CLI/plan output, not the state file itself, and that password authenticates a Postgres user the dcp stack grants DDL on. The planner also holds a resource-scoped `secretAccessor` grant on the `dc-api-key` secret, and `roles/iam.securityReviewer`, which permits reading every IAM policy binding in the project. So: no mutation, but broad read, including at least one live credential.

The other six are not reachable the same way, and the strength of that guarantee differs between them:

- `dfo-infra-applier` is bound to `attribute.repo_env_ref`, the repository id plus the job's `environment` and `ref` claims: `dev` on `refs/heads/dev` here. A `pull_request`-triggered run carries the PR's merge ref (`refs/pull/<n>/merge`), so no pull-request run can present a token this binding accepts. A `pull_request_target` run carries the default branch's ref, `refs/heads/main`, which matches neither dev binding's ref.
- In prod, `plan-prod.yml`'s plan job runs on `pull_request_target`, carries `refs/heads/main`, and runs the PR's Terraform. So prod binds each of the two identities to a GitHub Environment as well as `refs/heads/main`, through `attribute.repo_env_ref`. The applier needs `production`, which `apply-stack.yml` declares for `dfo-prod`. The planner needs `plan`, which only that plan job declares. The plan job's token carries `plan` and so never matches the applier. `scripts/setup-github-repos.sh --apply` creates both environments on the infra repo with a deployment branch policy that admits only `main`, and `scripts/handoff.sh dfo-prod infra` writes their values.
- `dfo-ai-deployer`, `dfo-apis-deployer`, `dfo-dcp-deployer` and `dfo-website-staging-deployer` are each pinned to a GitHub Environment and one branch ref at once (`attribute.repo_env_ref`). A job must declare that environment and run with that branch's ref claim to present a subject the binding accepts. All four deploy `dev` from `refs/heads/dev`. Each environment and branch is the repository's `deploy_environment` and `deploy_branch` in `var.github_repositories`. Each binding names one environment and one ref, so a `pull_request`-triggered job, which carries the PR's merge ref (`refs/pull/<n>/merge`), cannot match even when it declares the right environment. That environment's deployment branch policy, configured on GitHub in the owning repository rather than in this Terraform, stands in front of each binding as a second line. `scripts/setup-github-repos.sh --apply` creates the environment and sets that policy, and is the only thing that should, because a bare PUT to the environment endpoint clears any policy already in place. `scripts/handoff.sh` writes the environment's values once it has checked the policy. Audit the current policy with `scripts/check-deploy-branch-policy.sh`.
- `dfo-docs-sync` is bound to the `docsync` environment on `refs/heads/dev` through `attribute.repo_env_ref`, and the environment admits only `dev`. A `pull_request` run carries `refs/pull/<n>/merge`, which neither the binding nor the branch policy admits. A `pull_request_target` run loads its workflow from `dev`, the default branch, so only a workflow already merged to `dev` can declare `docsync`.
- `dfo-site-qa-deployer` is bound to the site QA repository's `refs/heads/main` through `attribute.repo_ref`. No workflow in that repository runs on `pull_request_target` with `id-token: write`, so no pull-request run can present a token the binding accepts.
- `dfo-dcp-deployer`'s binding governs only the Artifact Registry push. The pin PR itself is opened by a GitHub App installation token, which this binding does not constrain.

## Recovery from a bad attribute condition

`google_iam_workload_identity_pool_provider.github`'s `attribute_condition` gates every deployer identity at once. If an edit to it (or to `var.github_owner_id` / `var.github_repositories`) ever rejects a token one of the workflows actually presents, every GitHub Actions run loses GCP access simultaneously, including `dfo-infra-applier`. The symptom is every workflow failing at the `google-github-actions/auth` step — a 403 from GCP's STS endpoint — not a Terraform error, and it shows up on the very next run of any of the five workflows, whichever happens first. No CI identity can fix this: the applier authenticates through the same broken provider. Recovery is a human running `terraform apply` in this stack locally, with their own owner-level `gcloud` credentials, to correct the condition.

## Bootstrap note

The first apply of this stack is necessarily manual (it creates the identities CI later runs as). Everything after that goes through the normal PR flow.
