# foundation (prod)

Prod's copy of the foundation stack. The `.tf` files are symlinks to `infra/stacks/foundation`; `infra/dfo-dev/foundation/README.md` describes what they build. This directory holds prod's backend, tfvars, and lock file.

## Apply order

Foundation applies first, before every other prod stack, since it creates the identities CI runs as. The first apply is manual, by a project owner with their own `gcloud` credentials. Apply it again once `dcp` has applied, to fill in the ingestion operator grants.

The planner binds to the infra repo's `plan` environment and the applier to its `production` environment, both on `main`. Run `just setup-github-repos --apply` before the first CI plan or apply, since it creates both environments with a branch policy that admits only `main` and the `release` team as reviewers. Then run `just ENV=dfo-prod handoff infra`, which reads `workload_identity_provider`, `planner_service_account`, and `applier_service_account` from this stack and sets `WIF_PROVIDER` and `WIF_PLAN_SA` in the `plan` environment, and `WIF_PROVIDER` and `WIF_APPLY_SA` in `production`, on `DevelopmentFinanceObservatory/infra`. The repo holds no WIF values of its own, so the plan and apply workflows fail at the auth step until they exist.

## Made by hand first

- The `prod-fin-observatory` project, linked to a billing account, with `serviceusage.googleapis.com` enabled.

- The state bucket `tf-state-dfo-prod-prod-fin-observatory`. The bucket grants `projectViewer` `roles/storage.legacyObjectReader`, left from the default object ACL it was created with, and the planner holds `roles/viewer`, so that grant lets it read every object in the bucket and its `objectViewer` grant on this repository's state prefixes restricts nothing. Remove the grant with

  ```sh
  gcloud storage buckets remove-iam-policy-binding gs://tf-state-dfo-prod-prod-fin-observatory \
    --member=projectViewer:prod-fin-observatory --role=roles/storage.legacyObjectReader --condition=None
  ```

  `--condition=None` names the unconditioned grant. The bucket also holds the planner's conditional `objectViewer` grant, so gcloud refuses the command without it.

  Dev's bucket has no such grant.

- The `dfo-prod-foundation-principals` secret, which `scripts/bootstrap-principals.sh` writes, as `infra/dfo-dev/foundation/README.md` "Principals secret" describes, with `prod-fin-observatory` and `dfo-prod-foundation-principals` as its arguments. Prod's `ingestion_operators` object holds the ingestion group, and its `applier_impersonators` object is empty until the project owners who may impersonate the applier are added. Its `budget_alerts` object is empty until the budget has recipients beyond the billing admins. Plan fails while the secret does not exist.

- The `dc-api-key` secret, holding the Data Commons API key. The planner's access grant on it fails while the secret does not exist.

- The `dfo-prod-telemetry-principals` secret, which `scripts/bootstrap-principals.sh` writes (see `infra/dfo-prod/telemetry/README.md`). `principals_secret_stacks` in `env.auto.tfvars` lists `foundation`, `ai` and `telemetry`, and the planner's access grant on each secret fails while that secret does not exist.

## After the first apply

`env.auto.tfvars` sets `billing_export_dataset_id`, so this stack creates the `billing_export` dataset. A billing account admin then turns the export on in the console, as `infra/dfo-dev/foundation/README.md` "Billing export" describes.

## Placeholders in the tfvars

- `budget.auto.tfvars` leaves the Gemini budget off until the billing account and key project are known.
