# Maintainer notes

This page covers what a ONE Data maintainer needs to run this repository: access, Terraform state, CI, releases, wiring a service repository, and operating the dcp stack. Contributors who only edit Terraform need [CONTRIBUTING.md](../CONTRIBUTING.md).

## Prerequisites

- [just](https://github.com/casey/just), the task runner (`brew install just`).
- [uv](https://docs.astral.sh/uv/), which runs `uvx datacommons-cli`.
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or later.
- The [gcloud CLI](https://cloud.google.com/sdk/docs/install) with Application Default Credentials (`gcloud auth application-default login`).
- A Data Commons API key from [apikeys.datacommons.org](https://apikeys.datacommons.org).

Local plan and apply of the `dcp` stack read the Data Commons API key from the `dc-api-key` secret. An admin grants read access with `just grant-dc-key <email>`, after which you run `just bootstrap`.

## Environments

| Environment | GCP project            | Namespace  | Region                    |
| ----------- | ---------------------- | ---------- | ------------------------- |
| `dfo-dev`   | `dev-fin-observatory`  | `dfo-dev`  | `northamerica-northeast1` |
| `dfo-prod`  | `prod-fin-observatory` | `dfo-prod` | `europe-west1`            |

Recipes default to the `dcp` stack in `dfo-dev`. `ENV=dfo-prod` selects prod, and the project follows `ENV`.

## State

Dev state lives in `gs://tf-state-dfo-dev-dev-fin-observatory`, with one prefix per stack at `terraform/state/dfo-dev/<stack>`. Prod state lives in `gs://tf-state-dfo-prod-prod-fin-observatory` under `terraform/state/dfo-prod/<stack>`.

## CI

CI applies changes. The repository has two long-lived branches. `dev` is the integration branch and deploys dfo-dev. `main` deploys dfo-prod. A release is a pull request from `dev` into `main`.

### Pull requests into dev

A pull request into `dev` runs `.github/workflows/plan.yml`. It checks formatting across `infra/`, works out which stacks under `infra/dfo-dev` the change touches, and posts a `terraform plan` for each as its own pull request comment. Plans run as the read-only `dfo-infra-planner` service account over Workload Identity Federation, in the `dev-plan` GitHub environment.

`dev` requires no approval and three checks:

- `terraform fmt check` covers formatting.
- `Changed stacks planned` fails unless every changed stack planned and cleared the destroy guard.
- `Prod pin placeholder unchanged` fails a pull request that edits `infra/dfo-prod/dcp/image.auto.tfvars`.

The per-stack `plan (<stack>)` jobs are not required, since a matrix job exists only for a changed stack. A pull request that deletes or renames a stack root fails `Detect changed stacks` until it carries the `allow-destroy` label, so destroy the stack's resources first. A draft pull request runs no jobs in `plan.yml`, `plan-prod.yml` or `prod-pin-placeholder.yml`. Marking it ready starts them.

Merging to `dev` runs `.github/workflows/apply.yml`, which applies the stacks changed since the branch's previous commit to dfo-dev as the privileged `dfo-infra-applier`, in the `dev` GitHub environment. Nothing gates the apply inside the workflow. The review and the required checks are the gate.

### Pull requests into main

A pull request into `main` runs `.github/workflows/plan-prod.yml`, which plans `infra/dfo-prod` on `pull_request_target`, the one event whose token carries `refs/heads/main`. `Prod PR verified` rejects a head from a fork and checks that the pull request's merge commit has the base and head commits as its parents. The plan job then waits in the `plan` environment for a `release` team member to approve it, and plans that merge commit as `Prod plan (<stack>)`. The job runs the merge commit's Terraform and every script from a separate checkout of `main`. The prod planner's WIF binding requires the `plan` environment, and the prod applier's requires `production`, so the planner token never matches the applier.

`main` requires one approval, `terraform fmt check` and `Prod changed stacks planned`. A release pull request's head is a branch cut from `dev`, so updating it from `main` is a push to a branch the `dev` ruleset does not cover. Merging to `main` runs `apply.yml` against dfo-prod, and each apply job waits in the `production` environment for the `release` team.

### Destroy guard

Both plan workflows run `terraform plan -out=tfplan` and pass the saved plan to `scripts/check-destroys.sh`. It fails the job if the plan would delete or replace a Spanner instance or database, a Cloud SQL instance or database, a GCS bucket, a BigQuery dataset or reservation, a Secret Manager secret, or the consumer PSC network's VPC, subnetwork or reserved address. A replace counts as a delete. The dcp stack's per-run `null_resource` is exempt, since it changes on every plan and would otherwise block every dcp change. Add the `allow-destroy` label to the pull request to override, on the plan and on the merge that follows. `apply.yml` applies that saved plan, so what runs is what the guard cleared.

`google_storage_bucket.datasets_working` and `datasets_pinned` in `infra/stacks/dcp/dfo_datasets.tf` also carry `prevent_destroy`, which stops Terraform generating a destructive plan for them at all. That holds on the break-glass path below, where `check-destroys.sh` does not run.

### Principal addresses

Stacks read group and person addresses from hand-made Secret Manager secrets named `<namespace>-<stack>-principals`, each a JSON object of objects mapping labels to IAM members. Terraform prints a member in the id of every `*_iam_member` resource, `sensitive` or not. Before any terraform step, every plan and apply job runs `scripts/mask-principals.sh`, which masks each member, and its address without the `group:` or `user:` prefix, in the rest of the job's log. It masks each also lower-cased, since the provider and IAM lower-case emails in ids and policy reads, and URL-encoded in both cases. Masks cover logs only, so `.github/scripts/plan-comment.js` and `apply-comment.js` strip the same list in any letter case, through `redact-principals.js`, from the plan and apply comments and the job summary, and refuse to post Terraform output when the list is missing. The script fails the job if it cannot list the project's secrets or read a principals secret. The applier reads them through `roles/secretmanager.admin`. The planner needs `roles/secretmanager.secretAccessor` on each one, so grant it when you create the secret, or every plan in that environment fails until the grant exists. A pull request into `main` plans with `main`'s copy of `plan-prod.yml` and these scripts, so the release that brings them to `main` is planned without them. Release them to `main` on their own, before any release that carries a stack reading a `*-principals` secret. `scripts/mask-principals.test.sh` tests the mask script, `node --test .github/scripts/redact-principals.test.js` the redaction, and `node --test .github/scripts/comment-redaction.test.js` both comment scripts end to end.

### Re-applying and break-glass

`apply.yml` takes a `workflow_dispatch` with a `stack` input, for re-applying one stack from the head of the branch it is dispatched on (`dev` for dfo-dev, `main` for dfo-prod) without a commit that touches it.

If CI is unavailable, an owner with local apply credentials may apply directly with `just auth`, then `just STACK=<stack> apply`. Use this only as a fallback. It bypasses the pull request review, the plan-comment trail, and the destroy guard that CI runs at both plan and apply time, leaving `prevent_destroy` as the only backstop still in place.

## Wiring a service repository

A service repository's deploy workflows read GitHub App credentials and deploy variables from GitHub, and fail at the first step that reads a missing one.

1. Run `just setup-github-repos --apply` once to create each repository's rulesets, `dev` and `production` environments, and default branch. It prints its writes and makes none without `--apply`.
2. Run `just setup-github-apps` to set the App credentials in those environments. `just setup-github-apps --dry-run` prints the writes `scripts/setup-github-apps.sh` would make.
3. After `foundation` and the service's own stack have applied, run `just ENV=<env> handoff <stack>` for ai, apis, dcp, or website. dcp also needs `apis` applied.

This repository's own plan and apply workflows read `WIF_PROVIDER` and the planner or applier service account from their GitHub environments, and the repository holds none at repository level. After `foundation` applies, `just ENV=<env> handoff infra` sets them from foundation's outputs: the planner's in `dev-plan` (dfo-dev) or `plan` (dfo-prod), and the applier's in `dev` or `production`.

## Releasing to prod

Prod runs from `main` in each of the ten DevelopmentFinanceObservatory repositories. A release is a pull request from `dev` into `main`. Merging it deploys prod through the repository's `production` GitHub environment, which admits only `main` and requires the `release` team to approve the deployment.

Each repository's `main` ruleset requires one approval from someone with write access. `scripts/setup-github-repos.sh` writes these rulesets, the `dev` rulesets, the environments, and the `release` team's write access on the ten repositories. `scripts/setup-github-repos.test.sh` tests it against a stub `gh`. The `dcp` repository's `dev` ruleset allows merge commits only, because upstream syncs keep history shared with datacommonsorg/website through the merge's second parent, which a squash or rebase drops. This repository's `main` also requires `terraform fmt check` and `Prod changed stacks planned`. Other CI is not required, because prod pull request CI skips by design and a skipped required check passes.

Three GitHub Apps hold pin and sync credentials. `dfo-release` opens dcp's prod pin pull requests from dcp's `production` environment, and `dfo-pin` opens its dev pin pull requests from dcp's `dev` environment, both against this repository. `dfo-docsync` opens the docs repository's sync pull requests from its `docsync` environment. Run `just setup-github-apps` to set their credentials. `scripts/setup-github-apps.sh` refuses an environment that `scripts/setup-github-repos.sh` has not created.

## The dcp stack

### Deploy

```bash
cd infra/dfo-dev/dcp
terraform init && terraform apply
```

After `apply` completes, grant the operator `roles/spanner.databaseAdmin` and `roles/spanner.databaseUser` on the dcp database for `init-db` and `migrate-db`, and `roles/iam.serviceAccountTokenCreator` on the ingestion workflow service account (printed in the Terraform outputs) so the pipelines repository's ingestion assets can impersonate it:

```bash
gcloud iam service-accounts add-iam-policy-binding \
  <ingestion-workflow-sa>@<project>.iam.gserviceaccount.com \
  --member="user:<email>" \
  --role="roles/iam.serviceAccountTokenCreator"
```

Then initialise the database:

```bash
just init-db
```

### Shipping a new services image

dcp's Cloud Run service lives inside the pinned upstream stack module, which leaves nothing here for `lifecycle.ignore_changes` to target the way `ai` and `apis` do. Changing the image is an ordinary Terraform attribute change, so it goes through the plan and apply flow.

The `dcp` repository's CI builds and pushes the image, then opens (or force-pushes) a pull request here on the fixed branch `deploy/dcp-dev` that changes only `infra/dfo-dev/dcp/image.auto.tfvars`. The `dev` ruleset requires no approval, so the pull request auto-merges once its required checks pass. A GitHub App installation token scoped to dcp's `dev` GitHub environment opens it, and the WIF binding on `dfo-dcp-deployer` covers only the Artifact Registry push. `apply.yml` applies the pin like any other merge to `dev`. A routine deploy is a merge to the `dcp` repository's `dev` branch.

Two things this depends on live outside this repository's Terraform: auto-merge enabled on the `infra` GitHub repository, and dcp's `dev` GitHub environment existing with its deployment branch policy restricted to `dev`. `scripts/setup-github-repos.sh --apply` sets both.

For a break-glass deploy, `just deploy <image>` applies an image directly against live state with your own `gcloud` credentials, then pins it in `infra/dfo-dev/dcp/image.auto.tfvars` so the pin survives the next `apply`. Use it only when the automated path is unavailable. It bypasses the pull request review, the plan-comment trail, and the destroy guard. Commit the pin it writes. `image.auto.tfvars` is unowned in `.github/CODEOWNERS`, so committing it directly needs no code-owner review either.

### Upgrading the DCP module

```bash
just dcp-scaffold 1.1.6
```

The recipe regenerates `main.tf`, `variables.tf`, `outputs.tf`, and `README.md` from the upstream CLI at the given version. It copies the three `.tf` files over the tracked files in `infra/stacks/dcp`, which every environment's dcp root links to, and `README.md` into `infra/<ENV>/dcp`. It leaves `backend.tf` and `terraform.tfvars` untouched, because the CLI's own `backend.tf` assumes one stack per instance and would point this stack at empty state. [infra/dfo-dev/dcp/dfo.README.md](../infra/dfo-dev/dcp/dfo.README.md) explains why. It fails on uncommitted edits to `backend.tf` or any `dfo.*` file, so those do not blend into the diff it prints. It also checks the file set the CLI emitted against the expected six, which catches upstream drift the copy loop would otherwise drop silently.

The recipe only stages files. Read the diff, then run `terraform init` in that directory before `just plan`, because the module source ref moves on every version bump and the installed module goes stale until you do. Use plain `init`. The module source is the only change, and `-upgrade` would also re-resolve every provider and rewrite the committed `.terraform.lock.hcl`, which pins provider versions on purpose. `terraform init -backend=false` runs the same install with no GCP credentials, enough to regenerate and review an upgrade before you have a session. Then check the plan for relocated resources that need `moved` blocks before committing.

### Verify

After `init-db`, query the service for a node from Base DC's seeds to confirm it is up and reading the database. Replace `<service-url>` with the value from `terraform output`:

```bash
curl -sS -X POST <service-url>/core/api/v2/node \
  -H 'Content-Type: application/json' \
  -d '{"nodes":["country/BEL"],"property":"->name"}'
```
