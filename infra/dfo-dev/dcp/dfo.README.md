# dcp overlay — DFO-owned files

`main.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars`, `backend.tf`, and `README.md` are CLI-generated: `datacommons admin init --force` rewrites all six of them from templates, byte-for-byte, and never reads existing values or scans for other files. Any DFO logic that lived in those files would be silently clobbered on the next regen. The `.tf` files here, generated and DFO-owned alike, are symlinks into `infra/stacks/dcp`, which every environment's dcp directory shares. Terraform reads a symlinked `dfo_override.tf` as an override file all the same, since it goes by the file name.

`backend.tf` is wrong for this repo and must never be taken from CLI output. The CLI template assumes one stack per instance and writes `prefix = "terraform/state/dfo-dev"`. This repo runs six stacks under the `dfo-dev` instance name (`dcp`, `apis`, `ai`, `platform`, `foundation`, `website`), so this stack's real `backend.tf` reads `prefix = "terraform/state/dfo-dev/dcp"`. Taking the CLI's version points this stack at an empty state, and Terraform plans to create Spanner, GCS, Cloud Run, and everything else from scratch. `scripts/check-destroys.sh` won't catch it — it flags deletes and replacements, and a plan against empty state is all creates.

So all of our logic lives in a separate set of `dfo.*` files that the CLI never touches:

- `dfo.tf` — the Gemini API key wiring for the DFO prototype app (`null_resource.search_api_gemini_key`, reading the secret `var.search_api_gemini_api_key_secret_id` names, `dfo-dev-gemini-api-key` in dev and `dfo-prod-dcp-gemini-api-key` in prod, and the serving account's grant on that one secret), the Data Commons API key data source and its guard, and the `removed` block that retires the Cloud Run preprocessing job.
- `dfo_datasets.tf` — the Datasets API's GCS buckets, the garbage-collection service account and its access to them, and its database, migrator user, and garbage-collection database user on the shared Cloud SQL instance from the `platform` stack, plus its own `variable`/`output` blocks (kept out of `variables.tf`/`outputs.tf` for the same regen-safety reason). The Datasets API's serving identity — the Cloud Run runtime service account the `apis` stack creates — is out of scope here: its bucket grants, its signed-URL signing setup, and its runtime database user are declared in that stack, next to the identity they empower. It also revokes PUBLIC's default CONNECT on the datasets database (`google_sql_provision_script.datasets_revoke_public_connect`), owned here rather than in `platform` because the revoke is per-tenant and this is the tenant's own stack. The script grants CONNECT back to the migrator and garbage-collection users. The `apis` stack grants the runtime user its CONNECT (`google_sql_provision_script.runtime_connect`), so this stack names no `apis` role and applies first. Schema and table grants for the garbage-collection user belong to a migration in the owning repo. The applier here holds only `cloudsqlsuperuser`, which cannot grant on objects the migrator owns.
- `dfo_storage.tf` — the Data Commons artifacts bucket, taken out of the upstream storage module (via a `moved` block, `storage_create_artifacts_bucket = false` in `dfo.auto.tfvars`) so this stack can attach lifecycle rules the module has no input for. Deletes Dataflow's temp/staging objects under `ingestion/internal/temp/` after 7 days and per-run ingestion outputs under `ingestion/internal/datacommons/` after 30, and aborts incomplete multipart uploads after 7. Leaves `ingestion/input/` (uploaded source data) and `ingestion/internal/metadata/` (per-dataset version metadata the ingestion helper carries across runs) alone.
- `dfo_override.tf` — a Terraform _override_ file (see below), also the home for provider version floors above the CLI's own — its `terraform { required_providers {} }` block merges into main.tf's the same way its `module "stack"` block does.
- `dfo.auto.tfvars` — the committed, non-secret config, kept separate from the gitignored `terraform.tfvars`.
- `image.auto.tfvars` — the `datacommons_services_image` pin, split out of `dfo.auto.tfvars` and machine-written by the dcp repo's deploy workflows. Not edited by hand. It's unowned in `.github/CODEOWNERS`, since the pin PRs come from a GitHub App token and merge once the `dev` ruleset's checks pass. Nothing else belongs in it, since a second variable here would merge unreviewed.
- `dfo.README.md` — this file.

## The DC key redirection

The Data Commons API key is **not** in `dfo.auto.tfvars` and **not** read from `var.auth_google_datacommons_api_key` (that variable keeps its `""` default). Instead:

1. `dfo.tf` reads the key from the hand-created Secret Manager secret `dc-api-key` via `data "google_secret_manager_secret_version" "dc_key"`. (`dc-api-key` is the input secret, distinct from the module-managed `dfo-dev-dc-api-key` the stack creates downstream from this value.)
2. `dfo_override.tf` — a Terraform **override file** — rewrites only `module.stack`'s `auth_config` argument to merge that secret value in, replacing the empty var-sourced key. Terraform recognizes any `*_override.tf` file specially: its `module "stack" { ... }` block does not define a second module, it merges into the base block in `main.tf`, replacing only the arguments it names and leaving everything else (the `source` line the CLI matches on, `global`, `spanner_config`, etc.) intact.

This is how `main.tf` stays byte-identical to CLI output while still getting a Secret-Manager-sourced key: the override does the redirection, not `main.tf`.

## dcp plans always show a diff

Two resources appear in every plan. `null_resource.search_api_gemini_key` carries a `timestamp()` trigger, so it is replaced on every run. The Cloud Run web service shows an in-place update, because `dfo.tf` puts `GEMINI_API_KEY` on the revision out of band and Terraform reconciles it away again each time. Both are expected. The CI PR comment will never say "No changes" for dcp.

`skip_container_restarts` in `dfo.auto.tfvars` removes a third source of churn, the `FORCE_RESTART=timestamp()` the stack module otherwise stamps on its Cloud Run services on every apply.

## Rotation and seeding

- **Rotation**: add a new version to `dc-api-key`; `:latest` is read on the next apply.
- **Seeding**: the secret is hand-seeded by the owner (`gcloud secrets create` / `versions add`) and is not Terraform-managed. An empty or missing version trips the `dc_key_guard` precondition in `dfo.tf`, which hard-fails plan and apply rather than letting the module blank the live key.

## The database commands

Two `just` recipes touch the dcp database. Terraform grants none of the IAM they need, so grant it by hand before the first run.

| Recipe            | What it does                               | Spanner roles on your principal                             | Token creator on the workflow account |
| ----------------- | ------------------------------------------ | ----------------------------------------------------------- | ------------------------------------- |
| `just init-db`    | Creates the schema on a brand-new database | `roles/spanner.databaseAdmin`, `roles/spanner.databaseUser` | no                                    |
| `just migrate-db` | Applies pending Spanner schema migrations  | `roles/spanner.databaseAdmin`, `roles/spanner.databaseUser` | no                                    |

Terraform grants the workflow account `roles/workflows.viewer` (`ingestion_workflow_sa_viewer` in `dfo.tf`) on top of the stack module's `roles/workflows.invoker`. The pipelines repository's ingestion assets need it to read the workflow definition before they start an execution.

A permission error from any of these names the resource it denied rather than the principal it denied, which sends you to the wrong service account. Read the principal off the table first.

### init-db on an existing database

`init-db` skips a database whose `Node` table exists. If that check errors, the CLI treats the database as empty and applies the baseline schema under your own credentials. The schema's first statement, `CREATE TABLE Node`, then fails against an existing database before any DDL applies.

### Before running migrate-db

Take a Spanner backup. Migrations are forward-only, the framework has no `downgrade()`, and Spanner has no transactional DDL rollback. The CLI asks whether you have taken a backup and does not take one for you.

Then wait for a `terraform apply` on this stack to finish. `apply.yml` runs asynchronously, so a merged PR leaves the apply still in flight. These commands read their targets from `terraform output -json`, which stays empty until the apply populates state. `migrate-db` takes the ingestion lock in Spanner and fails while an ingestion holds it.

### Ingestion merges dcids across imports

Ingestion's preprocessing step always runs with `forceCombineNodes` set to true. A Node dcid declared by two imports merges into one node, whether those imports run separately or are reprocessed together later. Check for dcid collisions with what is already ingested before adding a new import.

## Migrator password rotation and recovery

`datasets_migrator_password_version` in `dfo_datasets.tf` and `presentation_migrator_password_version` in `dfo_presentation.tf` each control the write-only password for a Secret Manager version and Cloud SQL migrator user. For normal rotation, increment the relevant counter in a PR. After the PR merges, CI applies the whole dcp stack.

A partial apply can update one resource and fail on the other, leaving different passwords in Secret Manager and the SQL user. Retrying with the same counter can preserve the mismatch because Terraform generates a new ephemeral password and sends it to the resource that failed. For recovery, increment `datasets_migrator_password_version` for Datasets or `presentation_migrator_password_version` for Presentation in a PR. After the PR merges, wait for CI to finish applying the whole dcp stack before rerunning the migration job. One fresh password then reaches both resources.

## Revoking PUBLIC CONNECT is scoped per database

`google_sql_provision_script.datasets_revoke_public_connect` revokes CONNECT only on the `datasets` database. A new Postgres database always starts with CONNECT granted to PUBLIC, and `CREATE DATABASE` copies a template database's contents, not its `pg_database` ACL row, so revoking on `template1` does not make a later `CREATE DATABASE` inherit the revoke. `postgres` is already covered, by the `platform` stack's own copy of this resource (`google_sql_provision_script.postgres_revoke_public_connect`) against its own database, since `postgres` belongs to the instance rather than to any tenant. Whoever adds the next tenant database to the shared instance needs their own copy of this same resource, scoped to their own database. No instance-wide setting does it for them.

## Governance note

`dc-api-key` is hand-created and intentionally not a Terraform resource. Two consequences worth knowing:

- IAM changes on the secret (e.g. via `just grant-dc-key`) are not drift-detected by Terraform — nothing here reconciles its IAM policy against a declared state.
- Secret Manager Data Access audit logging is off by default in this project, so reads of this secret's value may not be logged anywhere.

Both are expected, not bugs.

## Orphaned Postgres role: `dfo-dev-dc-srvs-sa@dev-fin-observatory.iam`

`dfo_datasets.tf` used to grant the Datasets API's serving access to `dfo-dev-dc-srvs-sa`, the service account the upstream Data Commons stack module creates, on the theory that the Datasets API would run inside that container. It runs on its own Cloud Run service in the `apis` stack instead, under its own runtime identity, and that stack's `datasets_access.tf` now holds the equivalent grants for that identity.

Re-pointing a `google_sql_user` replaces it, and its `deletion_policy = "ABANDON"` meant Terraform dropped the old user from state without issuing the API delete. The role is still on the shared Cloud SQL instance, unused, and has to be dropped by hand.

The instance binds no VPC of its own, publishing a PSC service attachment that each consumer stack reaches through its own `consumer-psc-network`. This stack keeps none, so an operator at a laptop has no `psql` path to it. Use the Cloud SQL Admin API instead, which needs no network path. Confirm the name against the API first, because the instance is shared and production-adjacent:

```sh
gcloud sql users list --instance=dfo-dev-platform-postgres \
  --project=dev-fin-observatory

gcloud sql users delete "dfo-dev-dc-srvs-sa@dev-fin-observatory.iam" \
  --instance=dfo-dev-platform-postgres \
  --project=dev-fin-observatory
```

The role name is the service account email with `.gserviceaccount.com` trimmed and the `@<project>.iam` part kept. That is how Cloud SQL names `CLOUD_IAM_SERVICE_ACCOUNT` users, and the same `trimsuffix` that `datasets_access.tf` uses for the current runtime user, so any other orphaned IAM user follows the rule.

The delete can refuse with "role ... cannot be dropped because some objects depend on it". This role holds no grants, because the Datasets API's migrations have never run, so it should go cleanly. If that stops being true, `REASSIGN OWNED BY` to `dfo-dev-datasets-migrator` (which already owns the datasets schema) and then `DROP OWNED BY` clear the way.
