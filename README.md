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
│   └── dfo-dev/        # one directory per environment...
│       ├── dcp/        # ...one Terraform root (own state) per stack
│       ├── foundation/
│       ├── ai/
│       ├── apis/
│       ├── pipelines/
│       ├── platform/
│       └── website/
├── data/               # Datasets in Data Commons custom format (config.json + CSVs + variables.mcf)
└── scripts/
    └── load.sh         # Helper: stage a dataset into GCS and trigger ingestion
```

## Stacks

Each stack is an independent Terraform root: separate state, separate plan, separate blast radius. A change to one never shows up in another's plan.

| Stack                                  | Status | Owns                                                                                                                                                                                              |
| -------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [dcp](infra/dfo-dev/dcp)               | live   | The Data Commons Platform: upstream stack module (services, Spanner, Redis, ingestion) plus DFO additions in `dfo.tf`. The `dfo-dcp` repo's CI builds images and an auto-merged PR pins them here |
| [foundation](infra/dfo-dev/foundation) | live   | Shared plumbing: Artifact Registry, Workload Identity Federation, deployer service accounts                                                                                                       |
| [ai](infra/dfo-dev/ai)                 | live   | The AI service (agent harness + MCP servers). The `ai` repo's CI deploys images onto it                                                                                                           |
| [apis](infra/dfo-dev/apis)             | live   | The Search and Datasets APIs, on one Cloud Run service, with the storage, database and private-network access the Datasets API needs. The `apis` repo's CI deploys images onto it                 |
| [pipelines](infra/dfo-dev/pipelines)   | live   | Storage for the data pipelines, which the `dfo-pipelines` repo reads and writes.                                                                                                                  |
| [platform](infra/dfo-dev/platform)     | live   | The shared Cloud SQL Postgres instance, reached over Private Service Connect. Each tenant's database and users live in the tenant's own stack                                                     |
| [website](infra/dfo-dev/website)       | live   | The DFO website: a staging Cloud Run service, plus the private network path to the shared Postgres instance. The `dfo-website` repo's CI deploys images onto it                                   |

Each stack's README says what belongs in it. Resources land in a stack through normal PRs.

## State

All state lives in `gs://tf-state-dfo-dev-dev-fin-observatory`, one prefix per stack: `terraform/state/dfo-dev/<stack>`.

## CI

Changes go through CI rather than local applies. A pull request runs `.github/workflows/plan.yml`, which checks formatting across `infra/`, works out which of the stacks the change touches, and posts a `terraform plan` for each as its own PR comment. Plans run as the read-only `dfo-infra-planner` service account over Workload Identity Federation. Merging to `main` runs `.github/workflows/apply.yml`, which applies those same stacks as the privileged `dfo-infra-applier`. Nothing gates the apply inside the workflow. The review and the required checks on `main` are the gate. In ONEcampaign, `main` requires `terraform fmt check`, `Detect changed stacks`, and `Changed stacks planned`, which fails unless every changed stack planned and cleared the destroy guard. The per-stack `plan (<stack>)` jobs are not required, since a matrix job exists only for a changed stack. A PR that deletes or renames a stack root fails `Detect changed stacks` until it carries the `allow-destroy` label, so destroy the stack's resources first.

In the DevelopmentFinanceObservatory copy, `plan.yml` runs only `terraform fmt check`, because a `pull_request` run executes the PR's Terraform. `.github/workflows/plan-prod.yml` plans prod on `pull_request_target`: `Prod PR verified` runs `scripts/sync-guard.sh` from base `main` first, and only a PR it passes has its head checked out and planned as `Prod plan (<stack>)`. That job runs the head's Terraform and every script from a separate checkout of base `main`. It declares the `plan` environment, which the prod planner's WIF binding requires and the prod applier's, bound to `production`, never matches. Its `main` requires `terraform fmt check`, `Prod changed stacks planned`, and `sync-guard`. The names differ between the orgs because each file's jobs skip in the other org, and a skipped job counts as passed. dcp's auto-merged image-pin PRs have no human reviewer, so `approve-image-pin.yml` waits for `plan (dcp)` to succeed before approving.

Both workflows run `terraform plan -out=tfplan` and pass the saved plan to `scripts/check-destroys.sh`. It fails the job if the plan would delete or replace a Spanner instance or database, a Cloud SQL instance or database, a GCS bucket, a BigQuery dataset or reservation, a Secret Manager secret, or the consumer PSC network's VPC, subnetwork or reserved address. A replace counts as a delete. The dcp stack's per-run `null_resource` is exempt, since it churns on every plan and would otherwise block every dcp change. Add the `allow-destroy` label to the pull request to override, on the plan and on the merge that follows. `apply.yml` applies that same saved plan rather than re-planning, so what runs is what the guard cleared.

`google_storage_bucket.datasets_working` and `datasets_pinned` in `infra/stacks/dcp/dfo_datasets.tf` also carry `prevent_destroy`, which stops Terraform generating a destructive plan for them at all. That holds on the break-glass path below, where `check-destroys.sh` never runs.

`apply.yml` takes a `workflow_dispatch` with a `stack` input, for re-applying one stack from the head of `main` without a commit that touches it.

**Break-glass:** if CI is unavailable, an owner with local apply credentials may apply directly: `just auth`, then `just STACK=<stack> apply`. Use this only as a fallback, not for routine changes. It bypasses the PR review, the plan-comment trail, and the destroy guard that CI runs at both plan and apply time, leaving `prevent_destroy` as the only backstop still in place.

## Wiring a service repo

A service repo's deploy workflows read GitHub App credentials and deploy variables from GitHub, and fail at the first step that reads a missing one. Run `just ENV=<env> setup-github-apps` once per org to set the App credentials. After `foundation` and a service's own stack have applied, run `just ENV=<env> handoff <stack>` for ai, apis, dcp, or website; dcp also needs `apis` applied. `just setup-github-apps --dry-run` prints the writes `scripts/setup-github-apps.sh` would make.

This repo's own plan and apply workflows read `WIF_PROVIDER`, `WIF_PLAN_SA`, and `WIF_APPLY_SA` as repo variables. After `foundation` applies, `just ENV=<env> handoff infra` sets them on the env's infra repo from foundation's outputs.

## Releasing to prod

Prod runs from ten repos in the DevelopmentFinanceObservatory org, each a tree copy of a ONEcampaign commit. Dispatch `.github/workflows/sync.yml` in the new `infra` repo with a repo name and, optionally, a ONEcampaign commit. It defaults to the head of the source branch. `scripts/sync-release.sh` builds the tree with `scripts/sync-tree.sh`, commits it onto the target's `main` with a `Synced-from: ONEcampaign/<repo>@<sha>` trailer, opens a PR from `sync/<repo>/<sha>`, and closes the repo's other open sync PRs. Merging the PR is the release.

A sync may release the source branch's floor commit or any descendant of it. The floor is the newest commit on the source branch that touched a release-control path: `.github/workflows/sync-guard.yml` in every repo, and in infra also `.github/workflows/sync.yml`, `.github/workflows/plan-prod.yml`, `.github/actions/sync-guard/`, and the `scripts/sync-*.sh` scripts other than the test. A sync replaces the whole tree, so an older commit would put back an older guard, or delete it, and leave no PR able to pass. `sync-release.sh`, `push-first-snapshot.sh`, and the guard each work the floor out from the source branch's full history and refuse an older commit, naming the floor. They also refuse when no commit on the branch touched a control path. Rolling back to a commit older than the floor is therefore a roll forward: revert the change on the source branch and release the revert. A rollback that stays above the floor is a dispatch of `sync.yml` with the older commit, reviewed and merged like any other sync PR.

`sync-tree.sh` reads the source commit's tree into a private index and puts back the target `main`'s copy of `infra/dfo-prod/dcp/image.auto.tfvars`, which prod's dcp build owns. Working on git objects keeps file modes, symlinks, and dcp's submodule links. `sync-tree.sh` refuses a base whose copy of that path is anything but a regular file (mode `100644`), so a symlink there can never point prod at another environment's values. `scripts/sync-lib.sh` holds the repo table, the excluded path, the release-control paths, and the pin format.

Every repo, this one included, carries the same `.github/workflows/sync-guard.yml`. It runs the `.github/actions/sync-guard` action from infra's `main` on `pull_request_target`, which runs `scripts/sync-guard.sh` through `scripts/sync-guard-check.sh`. Every PR that passes is one commit whose only parent is the PR's base commit. A sync PR passes when its head tree equals the tree `sync-tree.sh` builds for the trailer's commit against that base, and that commit is on the source branch at or after its floor. An image-pin PR passes when `dfo-release[bot]` opened it, every commit the compare API lists between base and head is authored and committed by `dfo-release[bot]` with `commit.verification.verified` true, the pin file stays a regular file, and the only changed line is `datacommons_services_image = "<registry path>@sha256:<digest>"`, the line dfo-dcp's `build-and-pin.yml` writes. The new line keeps the registry path of the line it replaces and changes only the digest, so a pin cannot move prod to another region, project, or repository. The one exception is the first pin, when the base line is `null`. GitHub signs a commit an App makes through the API with no custom author or committer, so a commit pushed from a local git with the App's token fails. Everything else fails. In ONEcampaign, `.github/workflows/prod-pin-placeholder.yml` fails any PR that edits the excluded path, since prod never reads those edits.

The guard reports through a check run, since a required check matches by name and a PR could add its own workflow with a job called `sync-guard`. The guard job runs in each repo's `sync-guard` environment, whose deployment branch policy admits only `main`. A `pull_request_target` run takes the default branch as its ref, so it qualifies, and a run from any other branch or event cannot read the environment's secrets. The job mints a `dfo-release` token with checks write on its own repo, opens a `sync-guard` check run on the PR's head commit as `in_progress`, runs the guard, and closes the check run as success or failure with the guard's report as its summary. Each repo's `main` ruleset requires the status check `sync-guard` with `dfo-release` as its source, which the rulesets API calls `integration_id`, so a check of the same name from any other app does not count. The `dfo-release` installation needs Checks write to post the check run, and Commit statuses write, which GitHub requires of an app before it can be chosen as a check's source. GitHub also offers the app as a source only after it has posted a check run in the repo, so set the source after the first guard run. `sync.yml` runs in infra's `sync` environment, also limited to `main`, for the same reason.

Each repo's `main` ruleset also sets these, without which a passing guard does not fix what merges:

- Require branches to be up to date before merging (`strict_required_status_checks_policy: true`). With the parent rule above, the PR's base is then `main`'s head when it merges.
- Allow only merge commits (`allowed_merge_methods: ["merge"]`). A merge of a head whose only parent is `main`'s head has the head's tree, and it keeps the guarded commit, with its trailer and signature, in `main`'s history. Squash and rebase merges write new commits GitHub authors.
- Require one approval from the `release` team.

"Update branch" adds a merge commit, which the guard rejects. When `main` moves under an open PR, dispatch `sync.yml` again for the same commit, or let the dcp build open a new pin.

Three GitHub Apps hold the credentials, and none can write across orgs. `dfo-reader` belongs to ONEcampaign, is installed on its dfo source repos, and reads contents: the guard and `sync.yml` use it for every ONEcampaign read. `dfo-release` belongs to DevelopmentFinanceObservatory and is installed only on the ten new repos: it opens sync PRs and prod pin PRs and posts the `sync-guard` check run, and it never touches ONEcampaign. `dfo-bot` belongs to ONEcampaign and makes the dev writes, such as dfo-dcp's dev pin PR, which `approve-image-pin.yml` admits by its `dfo-bot[bot]` login.

In DevelopmentFinanceObservatory the reader App's `READER_APP_CLIENT_ID` variable and `READER_APP_PRIVATE_KEY` secret sit only in environments limited to `main`: `sync-guard` on every repo, infra's `sync` and `plan`, and `production` on ai and apis. No prod repo holds them at repo level. ONEcampaign keeps the reader pair at repo level. Each new repo's `sync-guard` environment also holds `RELEASE_APP_CLIENT_ID` and `RELEASE_APP_PRIVATE_KEY`, and infra's `sync` environment holds the same release pair. Run `just ENV=dfo-prod setup-github-apps` from dfo-infra to set all of them, and `just ENV=dfo-dev setup-github-apps` for the ONEcampaign repos that read with `dfo-reader`. The script, `scripts/setup-github-apps.sh`, creates each of those environments that does not exist yet and limits it to `main`.

An empty new repo gets its first commit from `scripts/push-first-snapshot.sh <source-repo> <sha>`, run by an admin. It builds the same tree, commits it with no parent, and prints the `git push` to run. Run `scripts/sync-tree.test.sh` after changing any of these scripts.

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

The `dfo-dcp` repo's CI builds and pushes the image, then opens (or force-pushes) a PR here on the fixed branch `deploy/dcp-dev` that changes only `infra/dfo-dev/dcp/image.auto.tfvars`. `.github/workflows/approve-image-pin.yml` checks that the diff is nothing but that pin, confirms the digest resolves in Artifact Registry, waits for `plan (dcp)` to succeed, then approves and auto-merges. The PR is opened by a GitHub App installation token scoped to dfo-dcp's `dev` GitHub Environment, which is what makes the merge trustworthy without a human reviewer: the WIF binding on `dfo-dcp-deployer` covers only the Artifact Registry push. `apply.yml` applies the pin like any other merge to `main`. A routine deploy is a merge to `dfo-dcp`'s `dev` branch, nothing more.

Two things this depends on live outside this repo's Terraform: auto-merge enabled on the `dfo-infra` GitHub repo, and dfo-dcp's `dev` GitHub Environment existing with its deployment branch policy restricted to `dev`. Both are already set up for the current dev instance.

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
