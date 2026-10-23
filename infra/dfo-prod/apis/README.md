# apis, prod

The prod root for the apis stack. Every `.tf` file here is a symlink into `infra/stacks/apis`, and `infra/dfo-dev/apis/README.md` documents that code. This directory holds the backend, the lock file, and the prod values in `env.auto.tfvars`.

## Apply order

Apply after `foundation`, `platform`, and `dcp`. Each commented line in `env.auto.tfvars` names the output it comes from: `datacommons_service_url` from `dcp`, and `psc_service_attachment_uri` and `dns_name` from `platform`. Uncomment them and copy the values in before the first plan, which fails with "No value for required variable" until they are set. The other cross-stack values follow from the namespace and are already filled in. `google_sql_provision_script.runtime_connect` grants CONNECT on databases `dcp` creates, so it fails if `dcp` has not applied. `platform`'s `allowed_consumer_projects` must list `prod-fin-observatory` for the PSC endpoint in `network.tf` to connect.

## Hand-made prerequisites

- Secret Manager secrets `dfo-prod-apis-gemini-api-key` (the service's key, `data.google_secret_manager_secret.gemini` in `main.tf`) and `dfo-prod-search-catalogue-gemini-api-key` (the search catalogue Job's key, `data.google_secret_manager_secret.search_catalogue_gemini` in `search_catalogue.tf`). Each holds a key from its own AI Studio project on the DFO billing account, so the billing export attributes spend by caller. Each must exist with a version before plan, since the data sources fail without it.
- The `dfo-apis-deployer` service account, created by `foundation`.

## Handoff

`scripts/handoff.sh dfo-prod apis` sets every variable and secret dfo-apis's `production` GitHub Environment reads: the project, region and registry from `foundation`, the WIF secrets from `foundation`, and the service, worker and job names from this stack's outputs (`service_name`, `datasets_worker_service_name`, `datasets_migrate_job_name`, `datasets_maintenance_job_name`, `presentation_migrate_job_name`, `coverage_job_name`, `origin_catalogue_job_name`, `graph_release_job_name`, `search_catalogue_job_name`). `deploy_values` in `scripts/deploy-targets.sh` maps each name to its output.

## Caller authentication

`env.auto.tfvars` sets `allow_unauthenticated = true` and an empty `invoker_members`. The prod `website` and `ai` stacks grant their own runtime service accounts `roles/run.invoker` on `dfo-prod-apis`. Prod has no eval reader. "Caller authentication" in `infra/dfo-dev/apis/README.md` describes the token each caller sends, the staged flip to `allow_unauthenticated = false`, and the break-glass command, which here names `dfo-prod-apis`, `--region europe-west1` and `--project prod-fin-observatory`.
