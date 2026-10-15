# foundation (prod)

Prod's copy of the foundation stack. The `.tf` files are symlinks to `infra/stacks/foundation`; `infra/dfo-dev/foundation/README.md` describes what they build. This directory holds prod's backend, tfvars, and lock file.

## Apply order

Foundation applies first, before every other prod stack, since it creates the identities CI runs as. The first apply is manual, by a project owner with their own `gcloud` credentials. Apply it again once `dcp` has applied, to fill in the ingestion operator grants.

The planner binds to the infra repo's `plan` environment and the applier to its `production` environment, both on `main`. Run `just setup-github-repos --apply` before the first CI plan or apply, since it creates both environments with a branch policy that admits only `main` and the `release` team as reviewers. Then run `just ENV=dfo-prod handoff infra`, which reads `workload_identity_provider`, `planner_service_account`, and `applier_service_account` from this stack and sets `WIF_PROVIDER` and `WIF_PLAN_SA` in the `plan` environment, and `WIF_PROVIDER` and `WIF_APPLY_SA` in `production`, on `DevelopmentFinanceObservatory/infra`. The repo holds no WIF values of its own, so the plan and apply workflows fail at the auth step until they exist.

## Made by hand first

- The `prod-fin-observatory` project, linked to a billing account, with `serviceusage.googleapis.com` enabled.
- The state bucket `tf-state-dfo-prod-prod-fin-observatory`.
- The `dc-api-key` secret, holding the Data Commons API key. The planner's access grant on it fails while the secret does not exist.

## After the first apply

`env.auto.tfvars` sets `billing_export_dataset_id`, so this stack creates the `billing_export` dataset. A billing account admin then turns the export on in the console, as `infra/dfo-dev/foundation/README.md` "Billing export" describes.

## Placeholders in the tfvars

- `applier_impersonators` in `env.auto.tfvars` is empty. Add the project owners who may impersonate the applier.
- `ingestion_operators` is empty, and the four `ingestion_*` names are commented out. Fill the names from `dcp`'s outputs after it applies, then add the operators.
- `budget.auto.tfvars` leaves the Gemini budget off until the billing account and key project are known.
