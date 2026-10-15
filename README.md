# DFO infrastructure

Terraform for the Development Finance Observatory's GCP infrastructure. The platform runs as a small number of Cloud Run services: the self-hosted [Data Commons Platform](https://docs.datacommons.org/custom_dc/quickstart.html) (dcp), the AI service, the Search and Datasets APIs, and the DFO website. This repo defines all of them, one Terraform root per environment × stack, each with its own state.

## Quick start

This repo uses [`just`](https://github.com/casey/just) for common tasks. Run `just` to list every recipe. Recipes default to the `dcp` stack in `dfo-dev`. Select others with `STACK=` / `ENV=`.

```bash
just auth                  # gcloud + application-default login
just bootstrap             # terraform init for the dcp stack
just plan                  # preview dcp changes
just STACK=foundation plan # preview another stack
just load data/oecd-wage   # stage a dataset and trigger ingestion
```

Local plan/apply of the `dcp` stack reads the Data Commons API key from the `dc-api-key` secret. Ask an admin to run `just grant-dc-key you@one.org`, then `just bootstrap`.

## Repository layout

```
dfo-infra/
├── infra/
│   ├── modules/        # DFO-owned reusable modules (empty until first consumer)
│   ├── dfo-dev/        # one directory per environment...
│   │   ├── dcp/        # ...one Terraform root (own state) per stack
│   │   ├── foundation/
│   │   ├── ai/
│   │   ├── apis/
│   │   ├── pipelines/
│   │   ├── platform/
│   │   └── website/
│   └── dfo-prod/       # the same stacks for prod, plus...
│       └── edge/       # ...the prod-only public edge
├── data/               # Datasets in Data Commons custom format (config.json + CSVs + variables.mcf)
└── scripts/
    └── load.sh         # Helper: stage a dataset into GCS and trigger ingestion
```

## Stacks

Each stack is an independent Terraform root: separate state, separate plan, separate blast radius. A change to one never shows up in another's plan.

| Stack                                  | Status | Owns                                                                                                                                                                                          |
| -------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [dcp](infra/dfo-dev/dcp)               | live   | The Data Commons Platform: upstream stack module (services, Spanner, Redis, ingestion) plus DFO additions in `dfo.tf`. The `dcp` repo's CI builds images and an auto-merged PR pins them here |
| [edge](infra/dfo-prod/edge)            |        | Prod only. developmentfinance.org's load balancer, its certificate, the Cloud Armor policy that admits only Cloudflare, and the Cloudflare zone's DNS and rules                               |
| [foundation](infra/dfo-dev/foundation) | live   | Shared plumbing: Artifact Registry, Workload Identity Federation, deployer service accounts                                                                                                   |
| [ai](infra/dfo-dev/ai)                 | live   | The AI service (agent harness + MCP servers). The `ai` repo's CI deploys images onto it                                                                                                       |
| [apis](infra/dfo-dev/apis)             | live   | The Search and Datasets APIs, on one Cloud Run service, with the storage, database and private-network access the Datasets API needs. The `apis` repo's CI deploys images onto it             |
| [pipelines](infra/dfo-dev/pipelines)   | live   | Storage for the data pipelines, which the `pipelines` repo reads and writes.                                                                                                                  |
| [platform](infra/dfo-dev/platform)     | live   | The shared Cloud SQL Postgres instance, reached over Private Service Connect. Each tenant's database and users live in the tenant's own stack                                                 |
| [website](infra/dfo-dev/website)       | live   | The DFO website: a Cloud Run service, plus the private network path to the shared Postgres instance. The `website` repo's CI deploys images onto it                                           |

Each stack's README says what belongs in it. Resources land in a stack through normal PRs.

## State

Dev state lives in `gs://tf-state-dfo-dev-dev-fin-observatory`, one prefix per stack: `terraform/state/dfo-dev/<stack>`. Prod state lives in `gs://tf-state-dfo-prod-prod-fin-observatory` under `terraform/state/dfo-prod/<stack>`.

## CI

Changes go through CI rather than local applies. Every repo has two long-lived branches. `dev` is the integration branch and deploys dfo-dev. `main` deploys dfo-prod. A release is a pull request from `dev` into `main`.

A pull request into `dev` runs `.github/workflows/plan.yml`. It checks formatting across `infra/`, works out which stacks under `infra/dfo-dev` the change touches, and posts a `terraform plan` for each as its own PR comment. Plans run as the read-only `dfo-infra-planner` service account over Workload Identity Federation, in the `dev-plan` GitHub environment. `dev` requires no approval. It requires `terraform fmt check`, `Changed stacks planned`, which fails unless every changed stack planned and cleared the destroy guard, and `Prod pin placeholder unchanged`, which fails a PR that edits `infra/dfo-prod/dcp/image.auto.tfvars`. The per-stack `plan (<stack>)` jobs are not required, since a matrix job exists only for a changed stack. A PR that deletes or renames a stack root fails `Detect changed stacks` until it carries the `allow-destroy` label, so destroy the stack's resources first. A draft pull request runs no jobs in `plan.yml`, `plan-prod.yml` or `prod-pin-placeholder.yml`; marking it ready starts them. Merging to `dev` runs `.github/workflows/apply.yml`, which applies the stacks changed since the branch's previous commit to dfo-dev as the privileged `dfo-infra-applier`, in the `dev` GitHub environment. Nothing gates the apply inside the workflow. The review and the required checks are the gate.

A pull request into `main` runs `.github/workflows/plan-prod.yml`, which plans `infra/dfo-prod` on `pull_request_target`, the one event whose token carries `refs/heads/main`. `Prod PR verified` rejects a head from a fork and checks that the PR's merge commit has the base and head commits as its parents. The plan job then waits in the `plan` environment for a `release` team member to approve it, and plans that merge commit as `Prod plan (<stack>)`. The job runs the merge commit's Terraform and every script from a separate checkout of `main`. The prod planner's WIF binding requires the `plan` environment, and the prod applier's requires `production`, so the planner token never matches the applier. `main` requires one approval, `terraform fmt check` and `Prod changed stacks planned`. A release PR's head is a branch cut from `dev`, not `dev` itself, so that updating it from `main` is a push to a branch the `dev` ruleset does not cover. Merging to `main` runs `apply.yml` against dfo-prod, and each apply job waits in the `production` environment for the `release` team.

Both workflows run `terraform plan -out=tfplan` and pass the saved plan to `scripts/check-destroys.sh`. It fails the job if the plan would delete or replace a Spanner instance or database, a Cloud SQL instance or database, a GCS bucket, a BigQuery dataset or reservation, a Secret Manager secret, or the consumer PSC network's VPC, subnetwork or reserved address. A replace counts as a delete. The dcp stack's per-run `null_resource` is exempt, since it churns on every plan and would otherwise block every dcp change. Add the `allow-destroy` label to the pull request to override, on the plan and on the merge that follows. `apply.yml` applies that same saved plan rather than re-planning, so what runs is what the guard cleared.

`google_storage_bucket.datasets_working` and `datasets_pinned` in `infra/stacks/dcp/dfo_datasets.tf` also carry `prevent_destroy`, which stops Terraform generating a destructive plan for them at all. That holds on the break-glass path below, where `check-destroys.sh` never runs.

`apply.yml` takes a `workflow_dispatch` with a `stack` input, for re-applying one stack from the head of the branch it is dispatched on (`dev` for dfo-dev, `main` for dfo-prod) without a commit that touches it.

**Break-glass:** if CI is unavailable, an owner with local apply credentials may apply directly: `just auth`, then `just STACK=<stack> apply`. Use this only as a fallback, not for routine changes. It bypasses the PR review, the plan-comment trail, and the destroy guard that CI runs at both plan and apply time, leaving `prevent_destroy` as the only backstop still in place.

## Wiring a service repo

A service repo's deploy workflows read GitHub App credentials and deploy variables from GitHub, and fail at the first step that reads a missing one. Run `just setup-github-repos --apply` once to create each repo's rulesets, `dev` and `production` environments, and default branch; it prints its writes and makes none without `--apply`. Run `just setup-github-apps` to set the App credentials in those environments. After `foundation` and a service's own stack have applied, run `just ENV=<env> handoff <stack>` for ai, apis, dcp, or website; dcp also needs `apis` applied. `just setup-github-apps --dry-run` prints the writes `scripts/setup-github-apps.sh` would make.

This repo's own plan and apply workflows read `WIF_PROVIDER` and the planner or applier service account from their GitHub environments, and the repo holds none at repo level. After `foundation` applies, `just ENV=<env> handoff infra` sets them from foundation's outputs: the planner's in `dev-plan` (dfo-dev) or `plan` (dfo-prod), and the applier's in `dev` or `production`.

## Releasing to prod

Prod runs from `main` in each of the ten DevelopmentFinanceObservatory repos. A release is a pull request from `dev` into `main`. Merging it deploys prod through the repo's `production` GitHub environment, which admits only `main` and requires the `release` team to approve the deployment.

Each repo's `main` ruleset requires one approval from someone with write access, and `scripts/setup-github-repos.sh` writes these rulesets, the `dev` rulesets, the environments, and the `release` team's write access on the ten repos. `scripts/setup-github-repos.test.sh` tests it against a stub `gh`. This repo's `main` also requires `terraform fmt check` and `Prod changed stacks planned`. Other CI is not required, because prod PR CI skips by design and a skipped required check passes.

Three GitHub Apps hold pin and sync credentials. `dfo-release` opens dcp's prod pin PRs from dcp's `production` environment, and `dfo-pin` opens its dev pin PRs from dcp's `dev` environment, both against this repo. `dfo-docsync` opens the docs repo's sync PRs from docs' `docsync` environment. Run `just setup-github-apps` to set their credentials; `scripts/setup-github-apps.sh` refuses an environment that `scripts/setup-github-repos.sh` has not created.

## The dcp stack: operations

### Deploy

```bash
cd infra/dfo-dev/dcp
terraform init && terraform apply
```

After `apply` completes, grant the operator `roles/iam.serviceAccountTokenCreator` on the ingestion workflow service account (printed in the Terraform outputs) so the CLI can impersonate it for `init-db`/`ingest`:

```bash
gcloud iam service-accounts add-iam-policy-binding \
  <ingestion-workflow-sa>@<project>.iam.gserviceaccount.com \
  --member="user:you@example.com" \
  --role="roles/iam.serviceAccountTokenCreator"
```

Then initialize the database:

```bash
just init-db
```

### Shipping a new services image

dcp's Cloud Run service lives inside the pinned upstream stack module, which leaves nothing here for `lifecycle.ignore_changes` to target the way `ai` and `apis` do. Changing the image is an ordinary Terraform attribute change, so it goes through the normal plan/apply flow instead of a direct CI deploy.

The `dcp` repo's CI builds and pushes the image, then opens (or force-pushes) a PR here on the fixed branch `deploy/dcp-dev` that changes only `infra/dfo-dev/dcp/image.auto.tfvars`. The `dev` ruleset requires no approval, so the PR auto-merges once its required checks pass. The PR is opened by a GitHub App installation token scoped to dcp's `dev` GitHub Environment, and the WIF binding on `dfo-dcp-deployer` covers only the Artifact Registry push. `apply.yml` applies the pin like any other merge to `dev`. A routine deploy is a merge to `dcp`'s `dev` branch, nothing more.

Two things this depends on live outside this repo's Terraform: auto-merge enabled on the `infra` GitHub repo, and dcp's `dev` GitHub Environment existing with its deployment branch policy restricted to `dev`. `scripts/setup-github-repos.sh --apply` sets both.

**Break-glass:** `just deploy <image>` applies an image directly against live state with your own `gcloud` credentials, then pins it in `infra/dfo-dev/dcp/image.auto.tfvars` so the pin survives the next `apply`. Use it only when the automated path above is unavailable. It bypasses the PR review, the plan-comment trail, and the destroy guard. Commit the pin it writes. `image.auto.tfvars` is unowned in `.github/CODEOWNERS`, so committing it directly needs no code-owner review either.

### Upgrading the DCP module

```bash
just dcp-scaffold 1.1.5
```

Regenerates `main.tf`, `variables.tf`, `outputs.tf`, and `README.md` from the upstream CLI at the given version. It copies the three `.tf` files over the tracked files in `infra/stacks/dcp`, which every environment's dcp root links to, and `README.md` into `infra/<ENV>/dcp`. It never touches `backend.tf` or `terraform.tfvars`: the CLI's own `backend.tf` assumes one stack per instance and would point this stack at empty state. See `infra/dfo-dev/dcp/dfo.README.md` for why. It hard-fails on uncommitted edits to `backend.tf` or any `dfo.*` file, so those don't blend into the diff it prints. It also checks the file set the CLI actually emitted against the expected six, catching upstream drift the copy loop would otherwise drop silently. The recipe only stages files. Read the diff, then run `terraform init` in that directory before `just plan`: the module source ref moves on every version bump, so the installed module goes stale until you do. Use plain `init`, not `-upgrade` — only the module source changed, and `-upgrade` would also re-resolve every provider and rewrite the committed `.terraform.lock.hcl`, which pins provider versions on purpose. `terraform init -backend=false` runs the same install with no GCP credentials at all, enough to regenerate and review an upgrade before you have a session. Then check the plan for relocated resources that need `moved` blocks before committing.

### Load data

```bash
just load data/oecd-wage
```

This clears the ingestion input bucket, uploads the dataset files, and triggers the ingestion workflow. Watch the Workflow console URL printed by the command to monitor progress. Provenance names in `config.json` must be space-free and lowercase-hyphenated. Spaces break the generated ingestion Dataflow job name.

### Verify

Once ingestion completes, query the service to confirm data is available. Replace `<service-url>` with the value from `terraform output`:

```bash
curl -sS -X POST <service-url>/core/api/v2/observation \
  -H 'Content-Type: application/json' \
  -d '{"select":["date","value","variable","entity"],"entity":{"dcids":["country/BEL"]},"variable":{"dcids":["average_annual_wage"]}}'
```

## Prerequisites

- [just](https://github.com/casey/just) — task runner (`brew install just`)
- [uv](https://docs.astral.sh/uv/) — for running `uvx datacommons-cli`
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) with Application Default Credentials (`gcloud auth application-default login`)
- A GCP project with billing enabled
- A Data Commons API key from [apikeys.datacommons.org](https://apikeys.datacommons.org)

## Current dev instance

- GCP project: `dev-fin-observatory`
- Namespace: `dfo-dev`
- Region: `northamerica-northeast1`
